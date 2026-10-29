package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Codex rollouts (~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<thread>.jsonl).
//
// response_item lines are the conversation in Responses API items. A
// token_count event follows every model call with that call's usage. The
// model's own items since the previous call (reasoning, assistant message,
// tool calls) are its response; every item before them is the input it was
// sent, as Codex over HTTP resends the full history. compacted lines
// replace the history. Instructions come from session_meta; tools are not
// in the rollout.

type rline struct {
	Timestamp string          `json:"timestamp"`
	Ordinal   int64           `json:"ordinal"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

var threadIDRe = regexp.MustCompile(`([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$`)

type codexFile struct {
	path, threadID, originator, cliVersion, cwd string
	instructions                                json.RawMessage
}

func modelItem(item map[string]any) bool {
	switch item["type"] {
	case "reasoning", "function_call", "custom_tool_call", "local_shell_call", "web_search_call", "image_generation_call", "tool_search_call":
		return true
	case "message":
		return item["role"] == "assistant"
	}
	return false
}

func readCodex(path string, out func(call), st *stats) (*codexFile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	cf := &codexFile{path: path}
	if m := threadIDRe.FindStringSubmatch(filepath.Base(path)); m != nil {
		cf.threadID = m[1]
	}
	type item struct {
		raw   json.RawMessage
		model bool
		ts    time.Time
	}
	var history []item
	pending := 0 // model items since the last call
	var model, effort string
	var lastInputTS time.Time
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 256<<20)
	for sc.Scan() {
		var l rline
		if json.Unmarshal(sc.Bytes(), &l) != nil {
			continue
		}
		ts := parseTS(l.Timestamp)
		switch l.Type {
		case "session_meta":
			var p struct {
				ID               string `json:"id"`
				Originator       string `json:"originator"`
				CLIVersion       string `json:"cli_version"`
				Cwd              string `json:"cwd"`
				BaseInstructions struct {
					Text string `json:"text"`
				} `json:"base_instructions"`
			}
			if json.Unmarshal(l.Payload, &p) == nil {
				if p.ID != "" {
					cf.threadID = p.ID
				}
				cf.originator, cf.cliVersion, cf.cwd = p.Originator, p.CLIVersion, p.Cwd
				if p.BaseInstructions.Text != "" {
					cf.instructions, _ = json.Marshal(p.BaseInstructions.Text)
				}
			}
		case "turn_context":
			var p map[string]any
			if json.Unmarshal(l.Payload, &p) == nil {
				if m, ok := p["model"].(string); ok && m != "" {
					model = m
				}
				for _, k := range []string{"effort", "reasoning_effort"} {
					if e, ok := p[k].(string); ok && e != "" {
						effort = e
					}
				}
			}
		case "compacted":
			var p struct {
				Message            string            `json:"message"`
				ReplacementHistory []json.RawMessage `json:"replacement_history"`
			}
			if json.Unmarshal(l.Payload, &p) == nil {
				history = history[:0]
				pending = 0
				if len(p.ReplacementHistory) > 0 {
					for _, r := range p.ReplacementHistory {
						history = append(history, item{raw: r, ts: ts})
					}
				} else if p.Message != "" {
					raw, _ := json.Marshal(map[string]any{"type": "message", "role": "user",
						"content": []map[string]string{{"type": "input_text", "text": p.Message}}})
					history = append(history, item{raw: raw, ts: ts})
				}
			}
		case "response_item":
			var it map[string]any
			if json.Unmarshal(l.Payload, &it) != nil {
				continue
			}
			isModel := modelItem(it)
			history = append(history, item{raw: l.Payload, model: isModel, ts: ts})
			if isModel {
				pending++
			} else if pending == 0 {
				lastInputTS = ts
			}
		case "event_msg":
			var p struct {
				Type string `json:"type"`
				Info *struct {
					Last struct {
						InputTokens           int64 `json:"input_tokens"`
						CachedInputTokens     int64 `json:"cached_input_tokens"`
						CacheWriteInputTokens int64 `json:"cache_write_input_tokens"`
						OutputTokens          int64 `json:"output_tokens"`
						ReasoningOutputTokens int64 `json:"reasoning_output_tokens"`
						TotalTokens           int64 `json:"total_tokens"`
					} `json:"last_token_usage"`
				} `json:"info"`
			}
			if json.Unmarshal(l.Payload, &p) != nil || p.Type != "token_count" || p.Info == nil || pending == 0 {
				continue
			}
			// The call's response: the trailing run of model items, which may
			// be interleaved with tool outputs already appended after them.
			first := -1
			seenModel := 0
			for i := len(history) - 1; i >= 0 && seenModel < pending; i-- {
				if history[i].model {
					seenModel++
					first = i
				}
			}
			c := call{source: "backfill:codex-rollout", requestID: "codex:" + cf.threadID + ":" + itoa(l.Ordinal),
				sessionID: "codex:" + cf.threadID, harness: codexHarness(cf.originator),
				userAgent: cf.originator + "/" + cf.cliVersion, originator: cf.originator,
				sourceFormat: "openai-response", provider: "codex", listKey: "input", model: model, effort: effort,
				cwd: cf.cwd, hasResponse: true}
			if len(cf.instructions) > 0 {
				c.whole = append(c.whole, piece{"instructions", cf.instructions})
			}
			var resp []json.RawMessage
			for i, h := range history {
				if i < first {
					c.items = append(c.items, h.raw)
				} else if h.model {
					resp = append(resp, h.raw)
				}
			}
			u := p.Info.Last
			c.inputTokens, c.outputTokens, c.reasoningTokens, c.totalTokens = u.InputTokens, u.OutputTokens, u.ReasoningOutputTokens, u.TotalTokens
			c.cacheReadTokens, c.cachedTokens, c.cacheCreationTokens = u.CachedInputTokens, u.CachedInputTokens, u.CacheWriteInputTokens
			c.response, _ = json.Marshal(map[string]any{"output": resp, "usage": u})
			params := map[string]any{"model": model, "stream": true}
			if effort != "" {
				params["reasoning"] = map[string]string{"effort": effort}
			}
			c.params, _ = json.Marshal(params)
			c.ts = lastInputTS
			if c.ts.IsZero() && first >= 0 {
				c.ts = history[first].ts
			}
			if !c.ts.IsZero() {
				c.latency = ts.Sub(c.ts)
			}
			c.notes = append(c.notes, "rebuilt from rollout: no tool definitions")
			st.add(c.source, 1)
			out(c)
			pending = 0
			// The next call goes out after this one's tool outputs, which the
			// rollout writes before the token_count.
			lastInputTS = ts
		}
	}
	return cf, sc.Err()
}

func codexHarness(originator string) string {
	if strings.Contains(strings.ToLower(originator), "t3") {
		return "t3"
	}
	return "codex"
}

func itoa(n int64) string {
	b, _ := json.Marshal(n)
	return string(b)
}
