package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/pluginapi"
	"gopkg.in/yaml.v3"

	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/dedup"
	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/sink"
)

const (
	version          = "0.1.0"
	maxSchemaVersion = 7
	sweepInterval    = 5 * time.Second
	// usage.handle and request.complete arrive separately; wait this long for
	// the other one before writing what we have.
	settleAfter = 20 * time.Second
	// An exchange that never finishes (lost hook) is written after this.
	staleAfter = 30 * time.Minute
)

type rawConfig struct {
	URL          string `yaml:"clickhouse-url"`
	User         string `yaml:"clickhouse-user"`
	Password     string `yaml:"clickhouse-password"`
	Database     string `yaml:"database"`
	QueueSize    int    `yaml:"queue-size"`
	BatchSize    int    `yaml:"batch-size"`
	FlushSeconds int    `yaml:"flush-seconds"`
	MaxBodyMB    int    `yaml:"max-body-mb"`
}

type plugin struct {
	log func(level, message string, fields map[string]any)

	configMu sync.Mutex
	config   *rawConfig
	sink     atomic.Pointer[sink.Sink]
	maxBody  atomic.Int64

	mu       sync.Mutex
	inFlight map[string]*exchange

	seen *seenSet

	startSweeper sync.Once
}

func newPlugin(log func(string, string, map[string]any)) *plugin {
	return &plugin{log: log, inFlight: map[string]*exchange{}, seen: newSeenSet(500_000)}
}

type exchange struct {
	id           string
	traceID      string
	firstSeen    time.Time
	settledAt    time.Time // first of usage/completion
	sourceFormat string
	model        string
	requested    string
	stream       bool
	transport    string
	reqHeaders   http.Header
	respHeaders  http.Header
	request      []byte
	response     bytes.Buffer
	wsEvents     bytes.Buffer
	overflow     bool
	status       int
	usage        *pluginapi.UsageRecord
	completion   *pluginapi.RequestCompletion
}

func (p *plugin) handle(method string, request []byte) (any, error) {
	switch method {
	case "plugin.register", "plugin.reconfigure":
		var req struct {
			ConfigYAML    []byte `json:"config_yaml"`
			SchemaVersion int    `json:"schema_version"`
		}
		if err := json.Unmarshal(request, &req); err != nil {
			return nil, fmt.Errorf("decode %s: %w", method, err)
		}
		p.configure(req.ConfigYAML)
		return registration(req.SchemaVersion), nil

	case "request.intercept_before":
		var ev pluginapi.RequestInterceptRequest
		if err := json.Unmarshal(request, &ev); err != nil {
			return nil, err
		}
		p.update(ev.RequestID, func(x *exchange) {
			x.traceID = ev.TraceID
			x.sourceFormat, x.model, x.requested, x.stream = ev.SourceFormat, ev.Model, ev.RequestedModel, ev.Stream
			x.reqHeaders = ev.Headers
			if strings.EqualFold(ev.Headers.Get("Upgrade"), "websocket") {
				x.transport = "websocket"
			}
			if len(x.request) == 0 {
				x.request = ev.Body
			}
		})
		return struct{}{}, nil

	case "request.intercept_after":
		return struct{}{}, nil

	case "response.intercept_after":
		var ev pluginapi.ResponseInterceptRequest
		if err := json.Unmarshal(request, &ev); err != nil {
			return nil, err
		}
		p.update(ev.RequestID, func(x *exchange) {
			x.sourceFormat, x.model, x.stream, x.status = ev.SourceFormat, ev.Model, ev.Stream, ev.StatusCode
			x.respHeaders = ev.ResponseHeaders
			if x.reqHeaders == nil {
				x.reqHeaders = ev.RequestHeaders
			}
			if len(x.request) == 0 {
				x.request = ev.OriginalRequest
			}
			x.response.Reset()
			p.appendCapped(x, &x.response, ev.Body)
		})
		return struct{}{}, nil

	case "response.intercept_stream_chunk":
		var ev pluginapi.StreamChunkInterceptRequest
		if err := json.Unmarshal(request, &ev); err != nil {
			return nil, err
		}
		p.update(ev.RequestID, func(x *exchange) {
			x.stream = true
			if ev.ChunkIndex == pluginapi.StreamChunkHeaderInitIndex {
				// A bootstrap retry repeats header-init; drop the failed attempt.
				x.response.Reset()
				x.overflow = false
				x.respHeaders = ev.ResponseHeaders
				if x.reqHeaders == nil {
					x.reqHeaders = ev.RequestHeaders
				}
				if len(x.request) == 0 {
					x.request = ev.OriginalRequest
				}
				return
			}
			p.appendCapped(x, &x.response, ev.Body)
		})
		return struct{}{}, nil

	case "websocket.response_event":
		var ev pluginapi.WebSocketResponseEvent
		if err := json.Unmarshal(request, &ev); err != nil {
			return nil, err
		}
		p.update(ev.RequestID, func(x *exchange) {
			x.transport = "websocket"
			if x.sourceFormat == "" {
				x.sourceFormat, x.model, x.requested = ev.SourceFormat, ev.Model, ev.RequestedModel
			}
			p.appendCapped(x, &x.wsEvents, ev.Payload)
			x.wsEvents.WriteByte('\n')
		})
		return struct{}{}, nil

	case "usage.handle":
		var rec pluginapi.UsageRecord
		if err := json.Unmarshal(request, &rec); err != nil {
			return nil, err
		}
		p.attachUsage(&rec)
		return struct{}{}, nil

	case "request.complete":
		var ev pluginapi.RequestCompletion
		if err := json.Unmarshal(request, &ev); err != nil {
			return nil, err
		}
		p.finish(ev.RequestID, func(x *exchange) {
			x.completion = &ev
			if x.traceID == "" {
				x.traceID = ev.TraceID
			}
		})
		return struct{}{}, nil

	case "plugin.quiesce", "plugin.shutdown":
		p.shutdown()
		return struct{}{}, nil
	}
	return nil, fmt.Errorf("unknown method %s", method)
}

func (p *plugin) appendCapped(x *exchange, buf *bytes.Buffer, b []byte) {
	if x.overflow {
		return
	}
	if limit := p.maxBody.Load(); limit > 0 && int64(buf.Len()+len(b)) > limit {
		x.overflow = true
		return
	}
	buf.Write(b)
}

func (p *plugin) get(id string) *exchange {
	x, ok := p.inFlight[id]
	if !ok {
		x = &exchange{id: id, firstSeen: time.Now(), transport: "http"}
		p.inFlight[id] = x
	}
	return x
}

func (p *plugin) update(id string, f func(*exchange)) {
	if id == "" || p.sink.Load() == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	f(p.get(id))
}

func (p *plugin) finish(id string, f func(*exchange)) {
	if id == "" || p.sink.Load() == nil {
		return
	}
	p.mu.Lock()
	x := p.get(id)
	f(x)
	ready := p.settle(x)
	p.mu.Unlock()
	if ready {
		p.record(x)
	}
}

// attachUsage pairs a usage record with its exchange. The host gives usage
// records their own RequestID, so they are matched on TraceID instead: one
// inbound HTTP request, or one Codex websocket connection carrying several
// turns. Within a trace, executions run one after another, so the oldest
// exchange still waiting for usage is the right one.
func (p *plugin) attachUsage(rec *pluginapi.UsageRecord) {
	if p.sink.Load() == nil {
		return
	}
	p.mu.Lock()
	var x *exchange
	if rec.TraceID != "" {
		for _, c := range p.inFlight {
			if c.traceID == rec.TraceID && c.usage == nil && (x == nil || c.firstSeen.Before(x.firstSeen)) {
				x = c
			}
		}
	}
	if x == nil {
		// No hooks saw this execution: keep the usage on its own.
		x = p.get("usage:" + rec.RequestID)
		x.traceID = rec.TraceID
	}
	x.usage = rec
	ready := p.settle(x)
	p.mu.Unlock()
	if ready {
		p.record(x)
	}
}

// settle reports whether x is complete and removes it if so. Callers hold p.mu.
func (p *plugin) settle(x *exchange) bool {
	if x.settledAt.IsZero() {
		x.settledAt = time.Now()
	}
	if x.usage == nil || x.completion == nil {
		return false
	}
	delete(p.inFlight, x.id)
	return true
}

func (p *plugin) sweep() {
	for range time.Tick(sweepInterval) {
		now := time.Now()
		var done []*exchange
		p.mu.Lock()
		for id, x := range p.inFlight {
			if (!x.settledAt.IsZero() && now.Sub(x.settledAt) > settleAfter) || now.Sub(x.firstSeen) > staleAfter {
				done = append(done, x)
				delete(p.inFlight, id)
			}
		}
		p.mu.Unlock()
		for _, x := range done {
			p.record(x)
		}
	}
}

func (p *plugin) record(x *exchange) {
	s := p.sink.Load()
	if s == nil {
		return
	}
	row, blobs := buildRow(x)
	var fresh []any
	var hashes []string
	for _, b := range blobs {
		if p.seen.has(b.Hash) {
			continue
		}
		hashes = append(hashes, b.Hash)
		fresh = append(fresh, blobRow{
			Hash: b.Hash, Kind: b.Kind, Role: b.Role, Type: b.Type,
			Bytes: len(b.Content), Content: string(b.Content), FirstSeen: row.TS,
		})
		row.NewBlobBytes += len(b.Content)
	}
	// Mark blobs as sent now, not after the insert, so concurrent requests in
	// the same batch don't each carry them; forget them again if dropped.
	p.seen.add(hashes)
	s.Enqueue(sink.Batch{Request: row, Blobs: fresh, OnDropped: func() { p.seen.remove(hashes) }})
}

type blobRow struct {
	Hash      string `json:"hash"`
	Kind      string `json:"kind"`
	Role      string `json:"role"`
	Type      string `json:"type"`
	Bytes     int    `json:"bytes"`
	Content   string `json:"content"`
	FirstSeen string `json:"first_seen"`
}

type requestRow struct {
	TS                   string            `json:"ts"`
	RequestID            string            `json:"request_id"`
	TraceID              string            `json:"trace_id"`
	SessionID            string            `json:"session_id"`
	ParentSessionID      string            `json:"parent_session_id"`
	Harness              string            `json:"harness"`
	UserAgent            string            `json:"user_agent"`
	Originator           string            `json:"originator"`
	ClientIP             string            `json:"client_ip"`
	ClientKeyHash        string            `json:"client_key_hash"`
	SourceFormat         string            `json:"source_format"`
	Transport            string            `json:"transport"`
	Provider             string            `json:"provider"`
	ExecutorType         string            `json:"executor_type"`
	AuthID               string            `json:"auth_id"`
	AuthIndex            string            `json:"auth_index"`
	AuthType             string            `json:"auth_type"`
	Account              string            `json:"account"`
	Model                string            `json:"model"`
	RequestedModel       string            `json:"requested_model"`
	Alias                string            `json:"alias"`
	ResponseModel        string            `json:"response_model"`
	ReasoningEffort      string            `json:"reasoning_effort"`
	ServiceTier          string            `json:"service_tier"`
	EffectiveServiceTier string            `json:"effective_service_tier"`
	Stream               bool              `json:"stream"`
	Outcome              string            `json:"outcome"`
	StatusCode           int               `json:"status_code"`
	Failed               bool              `json:"failed"`
	Error                string            `json:"error"`
	LatencyMS            int64             `json:"latency_ms"`
	TTFTMS               int64             `json:"ttft_ms"`
	InputTokens          int64             `json:"input_tokens"`
	OutputTokens         int64             `json:"output_tokens"`
	ReasoningTokens      int64             `json:"reasoning_tokens"`
	CachedTokens         int64             `json:"cached_tokens"`
	CacheReadTokens      int64             `json:"cache_read_tokens"`
	CacheCreationTokens  int64             `json:"cache_creation_tokens"`
	TotalTokens          int64             `json:"total_tokens"`
	RequestHeaders       map[string]string `json:"request_headers"`
	ResponseHeaders      map[string]string `json:"response_headers"`
	RequestBytes         int               `json:"request_bytes"`
	NewBlobBytes         int               `json:"new_blob_bytes"`
	Skeleton             string            `json:"skeleton"`
	BlobRefs             []string          `json:"blob_refs"`
	CacheControl         string            `json:"cache_control"`
	Response             string            `json:"response"`
	ResponseBytes        int               `json:"response_bytes"`
	WSEvents             string            `json:"ws_events"`
	Truncated            bool              `json:"truncated"`
	HasUsage             bool              `json:"has_usage"`
	HasCompletion        bool              `json:"has_completion"`
}

func buildRow(x *exchange) (requestRow, []dedup.Blob) {
	ts := x.firstSeen
	row := requestRow{
		RequestID: x.id, SourceFormat: x.sourceFormat, Transport: x.transport,
		Model: x.model, RequestedModel: x.requested, Stream: x.stream, StatusCode: x.status,
		RequestHeaders: cleanHeaders(x.reqHeaders), ResponseHeaders: cleanHeaders(x.respHeaders),
		RequestBytes: len(x.request), Response: x.response.String(), ResponseBytes: x.response.Len(),
		WSEvents: x.wsEvents.String(), Truncated: x.overflow,
		HasUsage: x.usage != nil, HasCompletion: x.completion != nil,
	}
	row.TraceID = x.traceID
	if c := x.completion; c != nil {
		row.Outcome, row.Error = string(c.Outcome), c.Error
		if c.StatusCode != 0 {
			row.StatusCode = c.StatusCode
		}
		if !c.StartedAt.IsZero() {
			ts = c.StartedAt
		}
		if row.Model == "" {
			row.Model, row.RequestedModel, row.SourceFormat, row.Stream = c.Model, c.RequestedModel, c.SourceFormat, c.Stream
		}
	}
	if u := x.usage; u != nil {
		if !u.RequestedAt.IsZero() {
			ts = u.RequestedAt
		}
		if row.TraceID == "" {
			row.TraceID = u.TraceID
		}
		row.SessionID, row.ParentSessionID = u.SessionID, u.ParentSessionID
		row.Provider, row.ExecutorType = u.Provider, u.ExecutorType
		row.AuthID, row.AuthIndex, row.AuthType, row.Account = u.AuthID, u.AuthIndex, u.AuthType, u.Source
		row.Alias, row.ResponseModel = u.Alias, u.ResponseModel
		row.ReasoningEffort, row.ServiceTier, row.EffectiveServiceTier = u.ReasoningEffort, u.ServiceTier, u.EffectiveServiceTier
		row.Failed = u.Failed
		if u.Failed && row.Error == "" {
			row.Error = u.Failure.Body
		}
		row.LatencyMS, row.TTFTMS = u.Latency.Milliseconds(), u.TTFT.Milliseconds()
		d := u.Detail
		row.InputTokens, row.OutputTokens, row.ReasoningTokens = d.InputTokens, d.OutputTokens, d.ReasoningTokens
		row.CachedTokens, row.CacheReadTokens, row.CacheCreationTokens, row.TotalTokens = d.CachedTokens, d.CacheReadTokens, d.CacheCreationTokens, d.TotalTokens
		if u.APIKey != "" {
			sum := sha256.Sum256([]byte("prometheus:" + u.APIKey))
			row.ClientKeyHash = hex.EncodeToString(sum[:8])
		}
		if len(u.ResponseHeaders) > 0 {
			for k, v := range cleanHeaders(u.ResponseHeaders) {
				if row.ResponseHeaders == nil {
					row.ResponseHeaders = map[string]string{}
				}
				row.ResponseHeaders[k] = v
			}
		}
		if row.Model == "" {
			row.Model = u.Model
		}
	}
	if row.Transport == "websocket" && row.Response == "" {
		row.ResponseBytes = x.wsEvents.Len()
	}
	h := x.reqHeaders
	row.UserAgent = h.Get("User-Agent")
	row.Originator = h.Get("Originator")
	row.ClientIP = strings.TrimSpace(strings.Split(h.Get("X-Forwarded-For"), ",")[0])
	if row.SessionID == "" {
		for _, k := range []string{"X-Claude-Code-Session-Id", "Session_id", "Session-Id", "X-Session-Id"} {
			if v := h.Get(k); v != "" {
				row.SessionID = v
				break
			}
		}
	}
	row.Harness = harness(row.UserAgent, row.Originator)
	row.TS = ts.UTC().Format(time.RFC3339Nano)

	split, err := dedup.SplitRequest(x.request)
	row.Skeleton = string(split.Skeleton)
	row.BlobRefs = split.Refs
	if row.BlobRefs == nil {
		row.BlobRefs = []string{}
	}
	if len(split.Patches) > 0 {
		cc, _ := json.Marshal(split.Patches)
		row.CacheControl = string(cc)
	}
	if err != nil && len(x.request) > 0 {
		row.Error = strings.TrimSpace(row.Error + " recorder: request not JSON: " + err.Error())
	}
	return row, split.Blobs
}

func harness(ua, originator string) string {
	l := strings.ToLower(ua + " " + originator)
	switch {
	case strings.Contains(l, "t3"):
		return "t3"
	case strings.Contains(l, "claude-cli") && strings.Contains(l, "sdk"):
		return "claude-sdk"
	case strings.Contains(l, "claude"):
		return "claude"
	case strings.Contains(l, "codex"):
		return "codex"
	case strings.Contains(l, "opencode"):
		return "opencode"
	}
	return "other"
}

// cleanHeaders flattens headers and drops anything that can carry a
// credential.
func cleanHeaders(h http.Header) map[string]string {
	out := map[string]string{}
	for k, v := range h {
		l := strings.ToLower(k)
		if l == "authorization" || l == "proxy-authorization" || l == "cookie" || l == "set-cookie" ||
			strings.Contains(l, "key") || strings.Contains(l, "token") || strings.Contains(l, "secret") {
			continue
		}
		out[l] = strings.Join(v, ", ")
	}
	return out
}

func (p *plugin) configure(raw []byte) {
	var cfg rawConfig
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		p.log("error", "recorder: invalid config, keeping previous settings", map[string]any{"error": err.Error()})
		return
	}
	if cfg.URL == "" {
		cfg.URL = "http://127.0.0.1:8123"
	}
	if cfg.Database == "" {
		cfg.Database = "prometheus"
	}
	if cfg.User == "" {
		cfg.User = "default"
	}
	if cfg.QueueSize <= 0 {
		cfg.QueueSize = 2048
	}
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 200
	}
	if cfg.FlushSeconds <= 0 {
		cfg.FlushSeconds = 2
	}
	if cfg.MaxBodyMB <= 0 {
		cfg.MaxBodyMB = 32
	}
	p.configMu.Lock()
	defer p.configMu.Unlock()
	if p.config != nil && reflect.DeepEqual(*p.config, cfg) {
		return
	}
	p.config = &cfg
	p.maxBody.Store(int64(cfg.MaxBodyMB) << 20)
	s := sink.New(sink.Config{
		URL: strings.TrimRight(cfg.URL, "/"), User: cfg.User, Password: cfg.Password, Database: cfg.Database,
		QueueSize: cfg.QueueSize, BatchSize: cfg.BatchSize, FlushInterval: time.Duration(cfg.FlushSeconds) * time.Second,
	}, p.log)
	if old := p.sink.Swap(s); old != nil {
		go closeSink(old)
	}
	p.log("info", "recorder: writing to ClickHouse", map[string]any{"url": cfg.URL, "database": cfg.Database})
	p.startSweeper.Do(func() { go p.sweep() })
}

func (p *plugin) shutdown() {
	p.configMu.Lock()
	defer p.configMu.Unlock()
	p.config = nil
	if s := p.sink.Swap(nil); s != nil {
		closeSink(s)
		stored, failed, dropped := s.Stats()
		p.log("info", "recorder: stopped", map[string]any{"stored": stored, "failed": failed, "dropped": dropped})
	}
}

func closeSink(s *sink.Sink) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s.Close(ctx)
}

type configField struct {
	Name        string
	Type        string
	Description string
}

func registration(hostSchemaVersion int) map[string]any {
	schema := min(max(hostSchemaVersion, 1), maxSchemaVersion)
	return map[string]any{
		"schema_version": schema,
		"metadata": map[string]any{
			"Name":             "recorder",
			"Version":          version,
			"Author":           "Nicolai Schmid",
			"GitHubRepository": "https://github.com/NicolaiSchmid/agent-infra",
			"ConfigFields": []configField{
				{"clickhouse-url", "string", "ClickHouse HTTP URL. Default: http://127.0.0.1:8123"},
				{"clickhouse-user", "string", "ClickHouse user. Default: default"},
				{"clickhouse-password", "string", "ClickHouse password."},
				{"database", "string", "Database holding the requests and blobs tables. Default: prometheus"},
				{"queue-size", "integer", "Requests buffered while ClickHouse is slow or down. Default: 2048"},
				{"batch-size", "integer", "Requests per insert. Default: 200"},
				{"flush-seconds", "integer", "Insert at least this often. Default: 2"},
				{"max-body-mb", "integer", "Responses beyond this are truncated. Default: 32"},
			},
		},
		"capabilities": map[string]bool{
			"request_interceptor":                 true,
			"request_interceptor_omit_body_after": true,
			"request_lifecycle_plugin":            true,
			"response_interceptor":                true,
			"response_stream_interceptor":         true,
			"websocket_response_observer":         true,
			"usage_plugin":                        true,
		},
	}
}

// seenSet remembers blob hashes ClickHouse already has, so a long session
// sends each message once. It forgets the oldest half when full; a forgotten
// blob is just sent again and collapsed by ReplacingMergeTree.
type seenSet struct {
	mu   sync.Mutex
	max  int
	cur  map[string]struct{}
	prev map[string]struct{}
}

func newSeenSet(max int) *seenSet {
	return &seenSet{max: max, cur: map[string]struct{}{}, prev: map[string]struct{}{}}
}

func (s *seenSet) has(h string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.cur[h]; ok {
		return true
	}
	if _, ok := s.prev[h]; ok {
		s.cur[h] = struct{}{}
		return true
	}
	return false
}

func (s *seenSet) remove(hs []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, h := range hs {
		delete(s.cur, h)
		delete(s.prev, h)
	}
}

func (s *seenSet) add(hs []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, h := range hs {
		s.cur[h] = struct{}{}
	}
	if len(s.cur) > s.max/2 {
		s.prev, s.cur = s.cur, map[string]struct{}{}
	}
}
