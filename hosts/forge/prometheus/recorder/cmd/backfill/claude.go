package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/dedup"
	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/rows"
)

// Claude Code transcripts (~/.claude/projects/<cwd>/<session>.jsonl, plus
// <session>/subagents/agent-*.jsonl).
//
// Since 2.1.281 Claude Code also logs every API request it sends:
//   - api-request: params (model, max_tokens, thinking, betas...), shapeHash,
//     base (previous request id) + keep (messages kept from it) + tail
//     (hashes of the messages appended), cacheControl (path, value) list
//   - api-request-shape: the system prompt and tools for a shapeHash
//   - api-request-blob: a message that isn't otherwise in the transcript
//
// Message hashes are sha256 of the message as compact JSON with sorted keys,
// cache_control lifted out, the same canonical form as internal/dedup. Tail
// hashes without a blob record are ordinary transcript lines (user lines, or
// assistant lines merged per message id, with or without thinking blocks).
// Those requests are rebuilt exactly ("backfill:claude-request-log").
//
// Older transcripts only have user/assistant lines. Each API call (assistant
// message id) is rebuilt from its parentUuid chain without system prompt or
// tools ("backfill:claude-transcript").

type cline struct {
	Type         string            `json:"type"`
	UUID         string            `json:"uuid"`
	ParentUUID   string            `json:"parentUuid"`
	IsSidechain  bool              `json:"isSidechain"`
	Message      json.RawMessage   `json:"message"`
	Timestamp    string            `json:"timestamp"`
	RequestRef   string            `json:"requestRef"`
	RequestID    string            `json:"requestId"`
	Entrypoint   string            `json:"entrypoint"`
	Cwd          string            `json:"cwd"`
	Version      string            `json:"version"`
	SessionID    string            `json:"sessionId"`
	AgentID      string            `json:"agentId"`
	Effort       string            `json:"effort"`
	ID           string            `json:"id"`
	Base         string            `json:"base"`
	Keep         int               `json:"keep"`
	Tail         []json.RawMessage `json:"tail"`
	CacheControl []struct {
		Path  []any           `json:"path"`
		Value json.RawMessage `json:"value"`
	} `json:"cacheControl"`
	Params        json.RawMessage `json:"params"`
	ShapeHash     string          `json:"shapeHash"`
	Shape         json.RawMessage `json:"shape"`
	Hash          string          `json:"hash"`
	QuerySource   string          `json:"querySource"`
	RequestDigest string          `json:"requestDigest"`
}

type cmsg struct {
	ID         string          `json:"id"`
	Model      string          `json:"model"`
	Role       string          `json:"role"`
	Content    json.RawMessage `json:"content"`
	StopReason string          `json:"stop_reason"`
	Usage      *struct {
		InputTokens              int64 `json:"input_tokens"`
		OutputTokens             int64 `json:"output_tokens"`
		CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
		CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
		OutputTokensDetails      struct {
			ThinkingTokens int64 `json:"thinking_tokens"`
		} `json:"output_tokens_details"`
	} `json:"usage"`
}

// agroup is one assistant API response: the transcript writes one line per
// content block, all with the same message id.
type agroup struct {
	id    string
	lines []*cline
	msgs  []cmsg
}

func (g *agroup) content(dropThinking bool) []json.RawMessage {
	var out []json.RawMessage
	for _, m := range g.msgs {
		var blocks []json.RawMessage
		if json.Unmarshal(m.Content, &blocks) != nil {
			continue
		}
		for _, b := range blocks {
			if dropThinking {
				var t struct {
					Type string `json:"type"`
				}
				_ = json.Unmarshal(b, &t)
				if t.Type == "thinking" || t.Type == "redacted_thinking" {
					continue
				}
			}
			out = append(out, b)
		}
	}
	return out
}

type claudeFile struct {
	path    string
	lines   []*cline
	byUUID  map[string]*cline
	groups  map[string]*agroup
	order   []*agroup
	reqs    []*cline
	reqByID map[string]*cline
	shapes  map[string]json.RawMessage
	// claude message hash (64 hex) -> canonical {role, content}
	known map[string][]byte

	sessionID, agentID, entrypoint, cwd, version string
}

func readClaude(path string) (*claudeFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	cf := &claudeFile{path: path, byUUID: map[string]*cline{}, groups: map[string]*agroup{},
		reqByID: map[string]*cline{}, shapes: map[string]json.RawMessage{}, known: map[string][]byte{}}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 256<<20)
	for sc.Scan() {
		var l cline
		if json.Unmarshal(sc.Bytes(), &l) != nil {
			continue
		}
		cl := &l
		if cf.sessionID == "" && l.SessionID != "" {
			cf.sessionID = l.SessionID
		}
		if l.AgentID != "" {
			cf.agentID = l.AgentID
		}
		if l.Entrypoint != "" {
			cf.entrypoint, cf.cwd, cf.version = l.Entrypoint, l.Cwd, l.Version
		}
		switch l.Type {
		case "user", "assistant":
			cf.lines = append(cf.lines, cl)
			if l.UUID != "" {
				cf.byUUID[l.UUID] = cl
			}
			if l.Type == "assistant" {
				var m cmsg
				if json.Unmarshal(l.Message, &m) == nil && m.ID != "" {
					g, ok := cf.groups[m.ID]
					if !ok {
						g = &agroup{id: m.ID}
						cf.groups[m.ID] = g
						cf.order = append(cf.order, g)
					}
					g.lines = append(g.lines, cl)
					g.msgs = append(g.msgs, m)
				}
			}
		case "attachment", "system", "progress":
			// part of the parentUuid chain, not API messages
			if l.UUID != "" {
				cf.byUUID[l.UUID] = cl
			}
		case "api-request":
			cf.reqs = append(cf.reqs, cl)
			cf.reqByID[l.ID] = cl
		case "api-request-shape":
			cf.shapes[l.ShapeHash] = l.Shape
		case "api-request-blob":
			if c, err := canonicalMsg(l.Message); err == nil {
				cf.known[l.Hash] = c
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if cf.sessionID == "" {
		cf.sessionID = strings.TrimSuffix(filepath.Base(path), ".jsonl")
	}
	// Index transcript messages by Claude's hash, for tail refs.
	for _, l := range cf.lines {
		if l.Type != "user" {
			continue
		}
		var m cmsg
		if json.Unmarshal(l.Message, &m) == nil {
			cf.remember(m.Role, m.Content)
			// A string prompt is sent as one text block.
			if len(m.Content) > 0 && m.Content[0] == '"' {
				blocks, _ := json.Marshal(contentBlocks(m.Content))
				cf.remember(m.Role, blocks)
			}
		}
	}
	for _, g := range cf.order {
		for _, drop := range []bool{false, true} {
			c, _ := json.Marshal(g.content(drop))
			cf.remember("assistant", c)
		}
	}
	cf.rememberRuns()
	return cf, nil
}

// rememberRuns indexes merged runs of consecutive same-role lines. The
// transcript writes parallel tool results (and some assistant turns) as
// separate lines; the API got them as one message.
func (cf *claudeFile) rememberRuns() {
	const maxRun = 40
	for i := 0; i < len(cf.lines); {
		j := i
		for j < len(cf.lines) && cf.lines[j].Type == cf.lines[i].Type {
			j++
		}
		if j-i > 1 {
			role := cf.lines[i].Type
			blocks := make([][]json.RawMessage, j-i)
			for k := i; k < j; k++ {
				var m cmsg
				if json.Unmarshal(cf.lines[k].Message, &m) == nil {
					blocks[k-i] = contentBlocks(m.Content)
				}
			}
			for a := 0; a < len(blocks); a++ {
				var acc []json.RawMessage
				for b := a; b < len(blocks) && b-a < maxRun; b++ {
					acc = append(acc, blocks[b]...)
					if b == a {
						continue
					}
					c, _ := json.Marshal(acc)
					cf.remember(role, c)
					if role == "assistant" {
						c, _ = json.Marshal(dropThinking(acc))
						cf.remember(role, c)
					}
				}
			}
		}
		i = j
	}
}

func dropThinking(blocks []json.RawMessage) []json.RawMessage {
	var out []json.RawMessage
	for _, b := range blocks {
		var t struct {
			Type string `json:"type"`
		}
		_ = json.Unmarshal(b, &t)
		if t.Type != "thinking" && t.Type != "redacted_thinking" {
			out = append(out, b)
		}
	}
	return out
}

func (cf *claudeFile) remember(role string, content json.RawMessage) {
	raw, _ := json.Marshal(map[string]json.RawMessage{"role": json.RawMessage(strconv.Quote(role)), "content": content})
	c, err := canonicalMsg(raw)
	if err != nil {
		return
	}
	sum := sha256.Sum256(c)
	cf.known[hex.EncodeToString(sum[:])] = c
}

// canonicalMsg is Claude Code's message hash input: compact JSON, sorted
// keys, no HTML escaping. Go escapes U+2028/2029 where JavaScript doesn't.
func canonicalMsg(raw []byte) ([]byte, error) {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	c, err := dedup.Canonical(v)
	if err != nil {
		return nil, err
	}
	c = bytes.ReplaceAll(c, []byte(` `), []byte(" "))
	return bytes.ReplaceAll(c, []byte(` `), []byte(" ")), nil
}

func (cf *claudeFile) harness() string {
	switch cf.entrypoint {
	case "sdk-ts":
		return "claude-sdk"
	case "cli", "":
		return "claude"
	}
	return "claude-" + cf.entrypoint
}

func (cf *claudeFile) session() (id, parent string) {
	if cf.agentID != "" {
		return "claude:" + cf.sessionID + ":" + cf.agentID, "claude:" + cf.sessionID
	}
	return "claude:" + cf.sessionID, ""
}

// emit sends one call per API request: from the request log where there is
// one, rebuilt from the chain for assistant messages it doesn't cover.
func (cf *claudeFile) emit(out func(call), st *stats) {
	covered := map[string]bool{}
	byRef := map[string][]*agroup{}
	for _, g := range cf.order {
		if ref := g.lines[0].RequestRef; ref != "" && cf.reqByID[ref] != nil {
			byRef[ref] = append(byRef[ref], g)
			covered[g.id] = true
		}
	}
	memo := map[string][]string{}
	var msgsOf func(r *cline, depth int) ([]string, bool)
	msgsOf = func(r *cline, depth int) ([]string, bool) {
		if m, ok := memo[r.ID]; ok {
			return m, true
		}
		var hs []string
		ok := true
		if r.Keep > 0 {
			b := cf.reqByID[r.Base]
			if b == nil || depth > 100000 {
				ok = false
			} else {
				prev, pok := msgsOf(b, depth+1)
				ok = pok
				hs = append(hs, prev[:min(r.Keep, len(prev))]...)
				if len(prev) < r.Keep {
					ok = false
				}
			}
		}
		for _, t := range r.Tail {
			var h string
			if json.Unmarshal(t, &h) != nil {
				// an inline message
				c, err := canonicalMsg(t)
				if err != nil {
					continue
				}
				sum := sha256.Sum256(c)
				h = hex.EncodeToString(sum[:])
				cf.known[h] = c
			}
			hs = append(hs, h)
		}
		memo[r.ID] = hs
		return hs, ok
	}
	sid, parent := cf.session()
	for _, r := range cf.reqs {
		hs, complete := msgsOf(r, 0)
		var shape struct {
			System json.RawMessage `json:"system"`
			Tools  json.RawMessage `json:"tools"`
		}
		_ = json.Unmarshal(cf.shapes[r.ShapeHash], &shape)
		c := call{source: "backfill:claude-request-log", requestID: r.ID, sessionID: sid, parentSessionID: parent,
			harness: cf.harness(), userAgent: fmt.Sprintf("claude-cli/%s (%s)", cf.version, cf.entrypoint),
			originator: r.QuerySource, sourceFormat: "claude", provider: "claude", params: r.Params,
			listKey: "messages", ts: parseTS(r.Timestamp), cwd: cf.cwd}
		if len(shape.System) > 0 && string(shape.System) != "null" {
			c.whole = append(c.whole, piece{"system", shape.System})
		}
		if len(shape.Tools) > 0 && string(shape.Tools) != "null" {
			c.whole = append(c.whole, piece{"tools", shape.Tools})
		}
		if !complete {
			c.notes = append(c.notes, "base request missing")
		}
		for _, h := range hs {
			if raw, ok := cf.known[h]; ok {
				c.items = append(c.items, raw)
			} else {
				c.items = append(c.items, nil)
				c.unresolved = append(c.unresolved, h)
			}
		}
		for _, cc := range r.CacheControl {
			c.patches = append(c.patches, dedup.Patch{Path: pointer(cc.Path), Value: cc.Value})
		}
		if gs := byRef[r.ID]; len(gs) > 0 {
			cf.fillResponse(&c, gs[len(gs)-1])
		}
		c.digest = "unchecked"
		if verifyDigests && r.RequestDigest != "" && complete && len(c.unresolved) == 0 && cf.shapes[r.ShapeHash] != nil {
			if cf.digest(r, c.items) == r.RequestDigest {
				c.digest = "match"
			} else {
				c.digest = "mismatch"
			}
			st.add("digest "+c.digest, 1)
		}
		st.add(c.source, 1)
		out(c)
	}
	for _, g := range cf.order {
		if covered[g.id] {
			continue
		}
		out(cf.fromChain(g, sid, parent, st))
	}
}

func (cf *claudeFile) fillResponse(c *call, g *agroup) {
	last := g.msgs[len(g.msgs)-1]
	resp := map[string]any{"id": g.id, "type": "message", "role": "assistant", "model": last.Model,
		"content": g.content(false), "stop_reason": last.StopReason, "usage": last.Usage}
	c.response, _ = json.Marshal(resp)
	c.responseModel = last.Model
	c.effort = g.lines[len(g.lines)-1].Effort
	if c.model == "" {
		c.model = last.Model
	}
	if u := last.Usage; u != nil {
		c.inputTokens, c.outputTokens = u.InputTokens, u.OutputTokens
		c.cacheReadTokens, c.cacheCreationTokens = u.CacheReadInputTokens, u.CacheCreationInputTokens
		c.reasoningTokens = u.OutputTokensDetails.ThinkingTokens
		c.totalTokens = u.InputTokens + u.OutputTokens + u.CacheReadInputTokens + u.CacheCreationInputTokens
	}
	first, end := parseTS(g.lines[0].Timestamp), parseTS(g.lines[len(g.lines)-1].Timestamp)
	if !c.ts.IsZero() && !first.IsZero() {
		c.ttft = first.Sub(c.ts)
		c.latency = end.Sub(c.ts)
	}
	c.hasResponse = true
}

// fromChain rebuilds the messages an older Claude Code sent for assistant
// message g: walk parentUuid back to the root, keep user/assistant lines,
// merge content blocks per assistant message id and runs of user lines.
func (cf *claudeFile) fromChain(g *agroup, sid, parent string, st *stats) call {
	var chain []*cline
	seen := map[string]bool{}
	for l := cf.byUUID[g.lines[0].ParentUUID]; l != nil && !seen[l.UUID]; l = cf.byUUID[l.ParentUUID] {
		seen[l.UUID] = true
		if l.Type == "user" || l.Type == "assistant" {
			chain = append(chain, l)
		}
	}
	type acc struct {
		role, id string
		blocks   []json.RawMessage
	}
	var msgs []acc
	for i := len(chain) - 1; i >= 0; i-- {
		var m cmsg
		if json.Unmarshal(chain[i].Message, &m) != nil {
			continue
		}
		blocks := contentBlocks(m.Content)
		if n := len(msgs); n > 0 && msgs[n-1].role == m.Role && (m.Role == "user" || msgs[n-1].id == m.ID) {
			msgs[n-1].blocks = append(msgs[n-1].blocks, blocks...)
			continue
		}
		msgs = append(msgs, acc{role: m.Role, id: m.ID, blocks: blocks})
	}
	c := call{source: "backfill:claude-transcript", requestID: firstNonEmpty(g.lines[0].RequestID, g.id),
		sessionID: sid, parentSessionID: parent, harness: cf.harness(),
		userAgent: fmt.Sprintf("claude-cli/%s (%s)", cf.version, cf.entrypoint), sourceFormat: "claude",
		provider: "claude", listKey: "messages", cwd: cf.cwd}
	for _, m := range msgs {
		raw, _ := json.Marshal(map[string]any{"role": m.role, "content": m.blocks})
		c.items = append(c.items, raw)
	}
	// The request went out right after the last chain line.
	if len(chain) > 0 {
		c.ts = parseTS(chain[0].Timestamp)
	}
	if c.ts.IsZero() {
		// No earlier line (first call of a file, or a broken chain): use the
		// response's own time.
		c.ts = parseTS(g.lines[0].Timestamp)
	}
	cf.fillResponse(&c, g)
	if c.model != "" {
		c.params, _ = json.Marshal(map[string]any{"model": c.model})
	}
	c.notes = append(c.notes, "rebuilt from transcript chain: no system prompt or tools")
	st.add(c.source, 1)
	return c
}

func contentBlocks(raw json.RawMessage) []json.RawMessage {
	var blocks []json.RawMessage
	if json.Unmarshal(raw, &blocks) == nil {
		return blocks
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		b, _ := json.Marshal(map[string]string{"type": "text", "text": s})
		return []json.RawMessage{b}
	}
	return nil
}

func pointer(path []any) string {
	var b strings.Builder
	for _, p := range path {
		b.WriteByte('/')
		switch v := p.(type) {
		case string:
			b.WriteString(strings.NewReplacer("~", "~0", "/", "~1").Replace(v))
		case float64:
			b.WriteString(strconv.Itoa(int(v)))
		default:
			fmt.Fprint(&b, v)
		}
	}
	return b.String()
}

func parseTS(s string) time.Time {
	t, _ := time.Parse(time.RFC3339Nano, s)
	return t
}

func firstNonEmpty(s ...string) string {
	for _, v := range s {
		if v != "" {
			return v
		}
	}
	return ""
}

var _ = rows.Request{}

// verifyDigests rebuilds each logged request in full and compares it with
// Claude Code's requestDigest: sha256 of params + system + tools + messages
// with cache_control applied, as canonical JSON.
var verifyDigests = true

func (cf *claudeFile) digest(r *cline, items [][]byte) string {
	doc := map[string]any{}
	if err := decodeNum(r.Params, &doc); err != nil {
		return ""
	}
	var shape map[string]any
	if err := decodeNum(cf.shapes[r.ShapeHash], &shape); err != nil {
		return ""
	}
	for k, v := range shape {
		doc[k] = v
	}
	msgs := make([]any, len(items))
	for i, raw := range items {
		if err := decodeNum(raw, &msgs[i]); err != nil {
			return ""
		}
	}
	doc["messages"] = msgs
	for _, cc := range r.CacheControl {
		var cur any = doc
		for _, p := range cc.Path {
			switch k := p.(type) {
			case string:
				m, _ := cur.(map[string]any)
				cur = m[k]
			case float64:
				l, _ := cur.([]any)
				if int(k) >= len(l) {
					return ""
				}
				cur = l[int(k)]
			}
		}
		m, ok := cur.(map[string]any)
		if !ok {
			return ""
		}
		var v any
		if decodeNum(cc.Value, &v) != nil {
			return ""
		}
		m["cache_control"] = v
	}
	raw, _ := json.Marshal(doc)
	c, err := canonicalMsg(raw)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(c)
	return hex.EncodeToString(sum[:])
}

func decodeNum(raw []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	return d.Decode(v)
}
