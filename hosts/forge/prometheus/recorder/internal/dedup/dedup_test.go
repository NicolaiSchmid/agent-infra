package dedup

import (
	"bytes"
	"encoding/json"
	"testing"
)

// Two consecutive Claude Code turns: the second resends the first turn's
// messages, and the cache breakpoint moves to the newest message.
const turn1 = `{"model":"claude-opus-5-5","system":[{"type":"text","text":"You are Claude Code.","cache_control":{"type":"ephemeral"}}],
"tools":[{"name":"Bash","input_schema":{"type":"object"}}],
"messages":[{"role":"user","content":[{"type":"text","text":"list files","cache_control":{"type":"ephemeral"}}]}]}`

const turn2 = `{"model":"claude-opus-5-5","system":[{"type":"text","text":"You are Claude Code.","cache_control":{"type":"ephemeral"}}],
"tools":[{"name":"Bash","input_schema":{"type":"object"}}],
"messages":[{"role":"user","content":[{"type":"text","text":"list files"}]},
{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls <dir>"}}]},
{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt","cache_control":{"type":"ephemeral"}}]}]}`

func TestSplitDedupesAcrossTurns(t *testing.T) {
	s1, err := SplitRequest([]byte(turn1))
	if err != nil {
		t.Fatal(err)
	}
	s2, err := SplitRequest([]byte(turn2))
	if err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{}
	for _, b := range s1.Blobs {
		known[b.Hash] = true
	}
	var fresh []Blob
	for _, b := range s2.Blobs {
		if !known[b.Hash] {
			fresh = append(fresh, b)
		}
	}
	// system, tools and the first user message are shared; only the assistant
	// tool_use and the tool_result are new.
	if len(fresh) != 2 {
		t.Fatalf("want 2 new blobs in turn 2, got %d: %+v", len(fresh), fresh)
	}
	if fresh[0].Role != "assistant" || fresh[1].Role != "user" {
		t.Fatalf("unexpected roles %q %q", fresh[0].Role, fresh[1].Role)
	}
}

func TestJoinRoundTrips(t *testing.T) {
	for _, in := range []string{turn1, turn2, `{"model":"gpt-5.6","instructions":"be brief","input":[{"type":"message","role":"user","content":"hi"}],"stream":true}`} {
		s, err := SplitRequest([]byte(in))
		if err != nil {
			t.Fatal(err)
		}
		blobs := map[string][]byte{}
		for _, b := range s.Blobs {
			blobs[b.Hash] = b.Content
		}
		out, err := Join(s.Skeleton, blobs, s.Patches)
		if err != nil {
			t.Fatal(err)
		}
		if !jsonEqual(t, []byte(in), out) {
			t.Fatalf("round trip differs:\n in: %s\nout: %s", in, out)
		}
	}
}

func TestNonObjectPassesThrough(t *testing.T) {
	s, _ := SplitRequest([]byte(`not json`))
	if !bytes.Equal(s.Skeleton, []byte(`not json`)) || len(s.Blobs) != 0 {
		t.Fatalf("unexpected split %+v", s)
	}
}

func jsonEqual(t *testing.T, a, b []byte) bool {
	t.Helper()
	var x, y any
	if err := json.Unmarshal(a, &x); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, &y); err != nil {
		t.Fatal(err)
	}
	ex, _ := json.Marshal(x)
	ey, _ := json.Marshal(y)
	return bytes.Equal(ex, ey)
}
