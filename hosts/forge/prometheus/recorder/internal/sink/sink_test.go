package sink

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeClickHouse accepts inserts only while up, and dedupes by token the way
// ClickHouse does with non_replicated_deduplication_window.
type fakeClickHouse struct {
	up     atomic.Bool
	mu     sync.Mutex
	tokens map[string]bool
	rows   map[string]int
}

func (f *fakeClickHouse) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !f.up.Load() {
		http.Error(w, "down", http.StatusServiceUnavailable)
		return
	}
	body, _ := io.ReadAll(r.Body)
	q := r.URL.Query()
	table := strings.Fields(q.Get("query"))[2]
	f.mu.Lock()
	defer f.mu.Unlock()
	if tok := q.Get("insert_deduplication_token"); tok != "" {
		if f.tokens[tok] {
			return
		}
		f.tokens[tok] = true
	}
	f.rows[table] += strings.Count(string(body), "\n")
}

func (f *fakeClickHouse) count(table string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.rows[table]
}

func newSink(t *testing.T, url, dir string) *Sink {
	return New(Config{
		URL: url, Database: "prometheus", QueueSize: 16, BatchSize: 1,
		FlushInterval: 20 * time.Millisecond, SpoolDir: dir, SpoolMaxBytes: 1 << 20,
	}, func(string, string, map[string]any) {})
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if cond() {
			return
		}
	}
	t.Fatal("timed out")
}

func TestSpoolsWhileDownAndReplaysInOrder(t *testing.T) {
	ch := &fakeClickHouse{tokens: map[string]bool{}, rows: map[string]int{}}
	srv := httptest.NewServer(ch)
	defer srv.Close()
	dir := t.TempDir()

	s := newSink(t, srv.URL, dir)
	for i := 0; i < 5; i++ {
		s.Enqueue(Batch{Request: map[string]int{"i": i}, Blobs: []any{map[string]int{"b": i}}})
	}
	waitFor(t, func() bool { _, _, _, n := s.Stats(); return n == 5 })
	files, _ := filepath.Glob(filepath.Join(dir, "*.ndjson"))
	if len(files) != 10 {
		t.Fatalf("want 10 spool files (blobs+requests x5), got %d", len(files))
	}
	// A restart picks the spool up from disk.
	s.Close(context.Background())
	s = newSink(t, srv.URL, dir)
	defer s.Close(context.Background())

	ch.up.Store(true)
	waitFor(t, func() bool { return ch.count("prometheus.requests") == 5 })
	if got := ch.count("prometheus.blobs"); got != 5 {
		t.Fatalf("want 5 blobs, got %d", got)
	}
	if files, _ := filepath.Glob(filepath.Join(dir, "*")); len(files) != 0 {
		t.Fatalf("spool not emptied: %v", files)
	}
	s.Enqueue(Batch{Request: map[string]int{"i": 5}})
	waitFor(t, func() bool { return ch.count("prometheus.requests") == 6 })
}

func TestReplayIsIdempotent(t *testing.T) {
	ch := &fakeClickHouse{tokens: map[string]bool{}, rows: map[string]int{}}
	ch.up.Store(true)
	srv := httptest.NewServer(ch)
	defer srv.Close()
	dir := t.TempDir()
	// Simulate an insert that landed but whose file was left behind.
	body := []byte("{\"i\":1}\n")
	name := "0000000000000000001-000001-1-requests"
	if err := os.WriteFile(filepath.Join(dir, name+".ndjson"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	ch.tokens[name] = true
	ch.rows["prometheus.requests"] = 1

	s := newSink(t, srv.URL, dir)
	defer s.Close(context.Background())
	waitFor(t, func() bool { files, _ := filepath.Glob(filepath.Join(dir, "*")); return len(files) == 0 })
	if got := ch.count("prometheus.requests"); got != 1 {
		t.Fatalf("replay double-inserted: %d rows", got)
	}
}

func TestSpoolFullDrops(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	s := New(Config{
		URL: srv.URL, Database: "prometheus", QueueSize: 1, BatchSize: 1,
		FlushInterval: 20 * time.Millisecond, SpoolDir: t.TempDir(), SpoolMaxBytes: 30,
	}, func(string, string, map[string]any) {})
	defer s.Close(context.Background())
	var dropped atomic.Int64
	for i := 0; i < 4; i++ {
		s.Enqueue(Batch{Request: map[string]string{"pad": "xxxxxxxxxx"}, OnDropped: func() { dropped.Add(1) }})
		time.Sleep(30 * time.Millisecond)
	}
	waitFor(t, func() bool { return dropped.Load() > 0 })
}
