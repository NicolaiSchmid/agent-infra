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
	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/rows"
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
	SpoolDir     string `yaml:"spool-dir"`
	SpoolMaxMB   int    `yaml:"spool-max-mb"`
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
	// done exchanges wait here for the worker, so hooks only copy bytes.
	done    chan *exchange
	dropped atomic.Int64
	stats   stats

	startSweeper sync.Once
}

func newPlugin(log func(string, string, map[string]any)) *plugin {
	return &plugin{log: log, inFlight: map[string]*exchange{}, seen: newSeenSet(500_000), done: make(chan *exchange, 1024)}
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

// handle times every hook call; the work it does runs on the proxy's
// request path.
func (p *plugin) handle(method string, request []byte) (any, error) {
	start := time.Now()
	out, err := p.dispatch(method, request)
	p.stats.hook(time.Since(start))
	return out, err
}

func (p *plugin) dispatch(method string, request []byte) (any, error) {
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

	case "response.intercept_after":
		var ev wireResponse
		cut, err := decodeLarge(request, &ev, []string{"OriginalRequest", "Body"}, []string{"RequestBody"})
		if err != nil {
			return nil, err
		}
		ev.OriginalRequest, ev.Body = cut[0], cut[1]
		p.update(ev.RequestID, func(x *exchange) {
			x.sourceFormat, x.model, x.stream, x.status = ev.SourceFormat, ev.Model, ev.Stream, ev.StatusCode
			x.respHeaders = ev.ResponseHeaders
			x.setRequest(ev.RequestHeaders, ev.OriginalRequest)
			x.response.Reset()
			p.appendCapped(x, &x.response, ev.Body)
		})
		return struct{}{}, nil

	case "response.intercept_stream_chunk":
		var ev wireStreamChunk
		cut, err := decodeLarge(request, &ev, []string{"OriginalRequest", "Body"}, []string{"RequestBody"})
		if err != nil {
			return nil, err
		}
		ev.OriginalRequest, ev.Body = cut[0], cut[1]
		p.update(ev.RequestID, func(x *exchange) {
			x.stream = true
			if ev.ChunkIndex == pluginapi.StreamChunkHeaderInitIndex {
				// A bootstrap retry repeats header-init; drop the failed attempt.
				x.response.Reset()
				x.overflow = false
				x.sourceFormat, x.model, x.requested = ev.SourceFormat, ev.Model, ev.RequestedModel
				x.respHeaders = ev.ResponseHeaders
				x.setRequest(ev.RequestHeaders, ev.OriginalRequest)
				return
			}
			p.appendCapped(x, &x.response, ev.Body)
		})
		return struct{}{}, nil

	case "websocket.response_event":
		var ev wireWebSocketEvent
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

func (x *exchange) setRequest(h http.Header, body []byte) {
	if x.reqHeaders == nil {
		x.reqHeaders = h
		if strings.EqualFold(h.Get("Upgrade"), "websocket") {
			x.transport = "websocket"
		}
	}
	if len(x.request) == 0 {
		x.request = body
	}
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
		p.enqueue(x)
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
		p.enqueue(x)
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
			p.enqueue(x)
		}
	}
}

func (p *plugin) enqueue(x *exchange) {
	select {
	case p.done <- x:
	default:
		if p.dropped.Add(1)%100 == 1 {
			p.log("warn", "recorder: worker behind, dropping requests", map[string]any{"dropped": p.dropped.Load()})
		}
	}
}

// work splits and encodes finished exchanges off the hook path.
func (p *plugin) work() {
	for x := range p.done {
		start := time.Now()
		p.record(x)
		p.stats.worker(time.Since(start), len(x.request))
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
		fresh = append(fresh, rows.Blob{
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

func buildRow(x *exchange) (rows.Request, []dedup.Blob) {
	ts := x.firstSeen
	row := rows.Request{
		RequestID: x.id, SourceFormat: x.sourceFormat, Transport: x.transport,
		Model: x.model, RequestedModel: x.requested, Stream: x.stream, StatusCode: x.status,
		RequestHeaders: cleanHeaders(x.reqHeaders), ResponseHeaders: cleanHeaders(x.respHeaders),
		RequestBytes: len(x.request), Response: x.response.String(), ResponseBytes: x.response.Len(),
		WSEvents: x.wsEvents.String(), Truncated: x.overflow,
		HasUsage: x.usage != nil, HasCompletion: x.completion != nil, Source: "live",
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
	if cfg.SpoolDir == "" {
		cfg.SpoolDir = "/CLIProxyAPI/recorder-spool"
	}
	if cfg.SpoolMaxMB <= 0 {
		cfg.SpoolMaxMB = 10240
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
		SpoolDir: cfg.SpoolDir, SpoolMaxBytes: int64(cfg.SpoolMaxMB) << 20,
	}, p.log)
	if old := p.sink.Swap(s); old != nil {
		go closeSink(old)
	}
	p.log("info", "recorder: writing to ClickHouse", map[string]any{"url": cfg.URL, "database": cfg.Database})
	p.startSweeper.Do(func() {
		go p.sweep()
		go p.reportStats()
		go p.work()
	})
}

func (p *plugin) shutdown() {
	p.configMu.Lock()
	defer p.configMu.Unlock()
	p.config = nil
	if s := p.sink.Swap(nil); s != nil {
		closeSink(s)
		stored, failed, dropped, spooled := s.Stats()
		p.log("info", "recorder: stopped", map[string]any{"stored": stored, "failed": failed, "dropped": dropped, "spooled": spooled})
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
				{"spool-dir", "string", "Batches ClickHouse hasn't accepted wait here and replay in order. Default: /CLIProxyAPI/recorder-spool"},
				{"spool-max-mb", "integer", "Spool size cap; beyond it requests are dropped. Default: 10240"},
			},
		},
		"capabilities": map[string]bool{
			"request_lifecycle_plugin":    true,
			"response_interceptor":        true,
			"response_stream_interceptor": true,
			"websocket_response_observer": true,
			"usage_plugin":                true,
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

// stats is the recorder's own cost, logged every statsInterval so the
// overhead on real traffic is visible in the proxy log.
type stats struct {
	hookCalls, hookNS, hookMaxNS     atomic.Int64
	requests, workerNS, requestBytes atomic.Int64
}

const statsInterval = 5 * time.Minute

func (s *stats) hook(d time.Duration) {
	s.hookCalls.Add(1)
	s.hookNS.Add(int64(d))
	for {
		cur := s.hookMaxNS.Load()
		if int64(d) <= cur || s.hookMaxNS.CompareAndSwap(cur, int64(d)) {
			return
		}
	}
}

func (s *stats) worker(d time.Duration, bytes int) {
	s.requests.Add(1)
	s.workerNS.Add(int64(d))
	s.requestBytes.Add(int64(bytes))
}

func (p *plugin) reportStats() {
	for range time.Tick(statsInterval) {
		s := &p.stats
		reqs := s.requests.Swap(0)
		calls, hookNS, maxNS := s.hookCalls.Swap(0), s.hookNS.Swap(0), s.hookMaxNS.Swap(0)
		workerNS, bytes := s.workerNS.Swap(0), s.requestBytes.Swap(0)
		if reqs == 0 {
			continue
		}
		f := map[string]any{
			"requests":           reqs,
			"hook_calls":         calls,
			"hook_ms_per_req":    float64(hookNS) / float64(reqs) / 1e6,
			"hook_max_ms":        float64(maxNS) / 1e6,
			"worker_ms_per_req":  float64(workerNS) / float64(reqs) / 1e6,
			"request_kb_per_req": bytes / reqs / 1024,
		}
		if sk := p.sink.Load(); sk != nil {
			stored, failed, dropped, spooled := sk.Stats()
			f["stored"], f["failed_inserts"], f["dropped"], f["spooled"] = stored, failed, dropped, spooled
		}
		// The host's log formatter drops most fields, so the numbers go in the text.
		p.log("info", fmt.Sprintf("recorder: stats requests=%d hook_ms_per_req=%.2f hook_max_ms=%.1f worker_ms_per_req=%.2f request_kb_per_req=%d stored=%v failed_inserts=%v dropped=%v spooled=%v",
			reqs, f["hook_ms_per_req"], f["hook_max_ms"], f["worker_ms_per_req"], f["request_kb_per_req"], f["stored"], f["failed_inserts"], f["dropped"], f["spooled"]), f)
	}
}
