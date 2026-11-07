package main

import (
	"encoding/json"
	"hash/maphash"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A rollout with two model calls: the first asks for a tool, the second
// answers after the tool output. Each call's input is everything before its
// own output; the tool output (written before the first token_count) belongs
// to the second call's input.
const rollout = `{"timestamp":"2026-09-20T19:58:20.000Z","type":"session_meta","payload":{"id":"01a0c065-eea8-73a0-8078-bbdc6abfcd21","originator":"t3code_desktop","cli_version":"0.163.0","base_instructions":{"text":"You are Codex."}}}
{"timestamp":"2026-09-20T19:58:21.000Z","type":"turn_context","payload":{"model":"gpt-6.1-sol","effort":"high"}}
{"timestamp":"2026-09-20T19:58:22.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"list files"}]}}
{"timestamp":"2026-09-20T19:58:23.000Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}
{"timestamp":"2026-09-20T19:58:23.500Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"c1","name":"exec","input":"ls"}}
{"timestamp":"2026-09-20T19:58:24.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"a.txt"}}
{"timestamp":"2026-09-20T19:58:24.100Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"reasoning_output_tokens":3,"total_tokens":110}}}}
{"timestamp":"2026-09-20T19:58:25.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a.txt"}]}}
{"timestamp":"2026-09-20T19:58:26.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":130,"cached_input_tokens":100,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":135}}}}
{"timestamp":"2026-09-20T19:58:26.100Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":130,"cached_input_tokens":100,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":135}}}}
`

func TestCodexCalls(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout-2026-09-20T21-58-20-01a0c065-eea8-73a0-8078-bbdc6abfcd21.jsonl")
	if err := os.WriteFile(path, []byte(rollout), 0o600); err != nil {
		t.Fatal(err)
	}
	var calls []call
	st := &stats{m: map[string]int64{}}
	if _, err := readCodex(path, func(c call) { calls = append(calls, c) }, st); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 {
		t.Fatalf("want 2 calls (repeated token_count ignored), got %d", len(calls))
	}
	types := func(items [][]byte) string {
		var out []string
		for _, raw := range items {
			var it map[string]any
			_ = json.Unmarshal(raw, &it)
			out = append(out, it["type"].(string))
		}
		return strings.Join(out, ",")
	}
	if got := types(calls[0].items); got != "message" {
		t.Fatalf("call 1 input: %s", got)
	}
	if got := types(calls[1].items); got != "message,reasoning,custom_tool_call,custom_tool_call_output" {
		t.Fatalf("call 2 input: %s", got)
	}
	c := calls[1]
	if c.inputTokens != 130 || c.cacheReadTokens != 100 || c.model != "gpt-6.1-sol" || c.effort != "high" || c.harness != "t3" {
		t.Fatalf("call 2 fields: %+v", c)
	}
	if c.sessionID != "codex:01a0c065-eea8-73a0-8078-bbdc6abfcd21" || len(c.whole) != 1 || c.whole[0].key != "instructions" {
		t.Fatalf("session/instructions: %s %+v", c.sessionID, c.whole)
	}
	// Call 2 went out after the tool output, not at the start of the turn.
	if got := c.ts.Format("15:04:05"); got != "19:58:24" {
		t.Fatalf("call 2 ts %s", got)
	}
	b := &builder{seed: maphash.MakeSeed(), memo: map[uint64]memoItem{}}
	row, blobs := b.build(c, "m", "")
	if len(row.BlobRefs) != 5 || len(blobs) != 5 || !strings.Contains(row.Skeleton, `"input":{"$refs":[1,5]}`) {
		t.Fatalf("row refs %v skeleton %s", row.BlobRefs, row.Skeleton)
	}
}
