package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/pluginapi"
)

// decodeLarge must agree with plain encoding/json on what the host sends,
// including bodies that contain quotes, field names and escapes.
func TestDecodeLargeMatchesJSON(t *testing.T) {
	tricky := []byte(`{"text":"say \"OriginalRequest\":\"x\" and \\   done"}`)
	in := pluginapi.StreamChunkInterceptRequest{
		RequestID: "r1", SourceFormat: "claude", Model: "m", RequestedModel: "rm",
		RequestHeaders:  http.Header{"User-Agent": {`a "Body":"b"`}},
		ResponseHeaders: http.Header{"X": {"y"}},
		OriginalRequest: tricky, RequestBody: []byte("upstream"), Body: []byte("data: {}\n\n"),
		ChunkIndex: -1, Metadata: map[string]any{"caller_scope": "s"},
	}
	raw, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var fast wireStreamChunk
	cut, err := decodeLarge(raw, &fast, []string{"OriginalRequest", "Body"}, []string{"RequestBody"})
	if err != nil {
		t.Fatal(err)
	}
	fast.OriginalRequest, fast.Body = cut[0], cut[1]
	var slow wireStreamChunk
	if err := json.Unmarshal(raw, &slow); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(fast.OriginalRequest, tricky) || !bytes.Equal(fast.Body, in.Body) ||
		fast.RequestID != slow.RequestID || fast.ChunkIndex != -1 || fast.RequestHeaders.Get("User-Agent") != in.RequestHeaders.Get("User-Agent") ||
		fast.RequestedModel != "rm" {
		t.Fatalf("mismatch:\nfast %+v\nslow %+v", fast, slow)
	}

	// Absent and null fields.
	raw, _ = json.Marshal(pluginapi.StreamChunkInterceptRequest{RequestID: "r2", ChunkIndex: 3, Body: []byte("x")})
	var e wireStreamChunk
	cut, err = decodeLarge(raw, &e, []string{"OriginalRequest", "Body"}, []string{"RequestBody"})
	if err != nil || cut[0] != nil || string(cut[1]) != "x" || e.ChunkIndex != 3 {
		t.Fatalf("null handling: %v %q %+v", err, cut, e)
	}
}
