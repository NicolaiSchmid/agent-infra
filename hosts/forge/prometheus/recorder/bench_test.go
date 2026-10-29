package main

// Cost of recording one request, measured on a real captured exchange:
//
//	RECORDER_BENCH_DIR=/path/with/body.json+resp.sse go test -run x -bench . -benchmem
//
// body.json is a client request body, resp.sse the SSE stream it produced.
// Neither is committed: they are someone's conversation.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/pluginapi"

	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/sink"
)

func benchData(b *testing.B) (body []byte, chunks [][]byte) {
	dir := os.Getenv("RECORDER_BENCH_DIR")
	if dir == "" {
		b.Skip("RECORDER_BENCH_DIR not set")
	}
	body, err := os.ReadFile(filepath.Join(dir, "body.json"))
	if err != nil {
		b.Fatal(err)
	}
	sse, err := os.ReadFile(filepath.Join(dir, "resp.sse"))
	if err != nil {
		b.Fatal(err)
	}
	for _, ev := range bytes.SplitAfter(sse, []byte("\n\n")) {
		if len(ev) > 0 {
			chunks = append(chunks, ev)
		}
	}
	return body, chunks
}

// call is what the host does per hook: marshal the payload (the host's
// rpc structs embed these pluginapi types), then the plugin decodes it.
func call(b *testing.B, p *plugin, method string, payload any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		b.Fatal(err)
	}
	if _, err := p.handle(method, raw); err != nil {
		b.Fatal(err)
	}
}

func benchPlugin() *plugin {
	p := newPlugin(func(string, string, map[string]any) {})
	p.sink.Store(sink.New(sink.Config{URL: "http://127.0.0.1:1", QueueSize: 1, BatchSize: 1, FlushInterval: time.Hour}, p.log))
	return p
}

// BenchmarkHooks: synchronous work on the proxy's request path, every hook
// call for one streamed request. The worker queue is drained, not recorded.
func BenchmarkHooks(b *testing.B) {
	body, chunks := benchData(b)
	p := benchPlugin()
	go func() {
		for range p.done {
		}
	}()
	hdr := http.Header{"User-Agent": {"claude-cli/2.1.302 (external, cli)"}, "Content-Type": {"application/json"}}
	b.SetBytes(int64(len(body)))
	b.ReportMetric(float64(len(chunks)), "chunks/op")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		id := strconv.Itoa(i)
		// request.intercept_before is not subscribed (see registration).
		call(b, p, "response.intercept_stream_chunk", pluginapi.StreamChunkInterceptRequest{RequestID: id, SourceFormat: "claude", RequestHeaders: hdr, OriginalRequest: body, RequestBody: body, ChunkIndex: pluginapi.StreamChunkHeaderInitIndex})
		for k, c := range chunks {
			call(b, p, "response.intercept_stream_chunk", pluginapi.StreamChunkInterceptRequest{RequestID: id, SourceFormat: "claude", RequestHeaders: hdr, Body: c, ChunkIndex: k})
		}
		call(b, p, "request.complete", pluginapi.RequestCompletion{RequestID: id, TraceID: id, Outcome: "succeeded", StatusCode: 200, StartedAt: time.Now(), CompletedAt: time.Now()})
		call(b, p, "usage.handle", pluginapi.UsageRecord{RequestID: "u" + id, TraceID: id, Detail: pluginapi.UsageDetail{InputTokens: 2, CacheReadTokens: 300000, OutputTokens: 900}})
	}
}

// BenchmarkRecord: background worker cost per request: dedup split, seen
// filter, JSON encoding for the insert. Steady state: earlier turns of the
// conversation are already stored, as in a long session.
func BenchmarkRecord(b *testing.B) {
	body, chunks := benchData(b)
	p := benchPlugin()
	x := &exchange{id: "r", firstSeen: time.Now(), request: body, transport: "http"}
	for _, c := range chunks {
		x.response.Write(c)
	}
	_, blobs := buildRow(x)
	for _, bl := range blobs[:len(blobs)-1] {
		p.seen.add([]string{bl.Hash})
	}
	b.SetBytes(int64(len(body)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		row, blobs := buildRow(x)
		var fresh []any
		for _, bl := range blobs {
			if !p.seen.has(bl.Hash) {
				fresh = append(fresh, blobRow{Hash: bl.Hash, Content: string(bl.Content)})
			}
		}
		if _, err := json.Marshal(row); err != nil {
			b.Fatal(err)
		}
		if _, err := json.Marshal(fresh); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkParseOnce: reference point, decoding the request body once,
// which the proxy itself does (and more) for every request.
func BenchmarkParseOnce(b *testing.B) {
	body, _ := benchData(b)
	b.SetBytes(int64(len(body)))
	for i := 0; i < b.N; i++ {
		var v map[string]any
		if err := json.Unmarshal(body, &v); err != nil {
			b.Fatal(err)
		}
	}
}
