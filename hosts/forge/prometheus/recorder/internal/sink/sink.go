// Package sink batches rows into ClickHouse over its HTTP interface.
//
// A batch ClickHouse doesn't accept goes to a spool directory on disk and is
// replayed, oldest first, once ClickHouse is back. Each spooled file is one
// insert with a fixed insert_deduplication_token, so a replay after an
// ambiguous failure (insert landed, response lost) stores nothing twice.
package sink

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	URL      string // e.g. http://127.0.0.1:8123
	User     string
	Password string
	Database string
	// QueueSize bounds requests waiting for the next flush.
	QueueSize     int
	FlushInterval time.Duration
	BatchSize     int
	// SpoolDir holds batches ClickHouse hasn't accepted yet. Empty disables
	// the spool: failed batches are kept in memory up to QueueSize.
	SpoolDir string
	// SpoolMaxBytes caps the spool; batches beyond it are dropped.
	SpoolMaxBytes int64
}

type Logger func(level, message string, fields map[string]any)

// Batch is what one finished request contributes: one requests row plus the
// blobs ClickHouse might not have yet.
type Batch struct {
	Request any
	Blobs   []any
	// OnDropped runs if the batch is given up on.
	OnDropped func()
}

type Sink struct {
	cfg    Config
	log    Logger
	client *http.Client
	queue  chan Batch
	done   chan struct{}
	wg     sync.WaitGroup
	seq    atomic.Int64

	// owned by run()
	spoolBytes int64
	spooled    bool // spool may hold files
	down       bool // last ClickHouse call failed; log transitions only

	stored, failed, dropped, spooledN atomic.Int64
}

func New(cfg Config, log Logger) *Sink {
	s := &Sink{
		cfg:    cfg,
		log:    log,
		client: &http.Client{Timeout: 30 * time.Second},
		queue:  make(chan Batch, cfg.QueueSize),
		done:   make(chan struct{}),
	}
	if cfg.SpoolDir != "" {
		if err := os.MkdirAll(cfg.SpoolDir, 0o700); err != nil {
			log("error", "recorder: spool disabled, cannot create dir", map[string]any{"dir": cfg.SpoolDir, "error": err.Error()})
			s.cfg.SpoolDir = ""
		} else {
			files, size := s.spoolFiles()
			s.spoolBytes, s.spooled = size, len(files) > 0
			if len(files) > 0 {
				log("info", "recorder: spool has pending batches", map[string]any{"files": len(files), "bytes": size})
			}
		}
	}
	s.wg.Add(1)
	go s.run()
	return s
}

// Enqueue never blocks the proxy: a full queue drops the request.
func (s *Sink) Enqueue(b Batch) {
	select {
	case s.queue <- b:
	default:
		if b.OnDropped != nil {
			b.OnDropped()
		}
		if s.dropped.Add(1)%100 == 1 {
			s.log("warn", "recorder: queue full, dropping requests", map[string]any{"dropped": s.dropped.Load()})
		}
	}
}

// Stats: requests stored, failed inserts, requests dropped, requests spooled.
func (s *Sink) Stats() (stored, failed, dropped, spooled int64) {
	return s.stored.Load(), s.failed.Load(), s.dropped.Load(), s.spooledN.Load()
}

func (s *Sink) Close(ctx context.Context) {
	close(s.done)
	ch := make(chan struct{})
	go func() { s.wg.Wait(); close(ch) }()
	select {
	case <-ch:
	case <-ctx.Done():
	}
}

func (s *Sink) run() {
	defer s.wg.Done()
	tick := time.NewTicker(s.cfg.FlushInterval)
	defer tick.Stop()
	var pending []Batch
	for {
		select {
		case b := <-s.queue:
			pending = append(pending, b)
			if len(pending) >= s.cfg.BatchSize {
				pending = s.flush(pending)
			}
		case <-tick.C:
			pending = s.flush(pending)
		case <-s.done:
			for {
				select {
				case b := <-s.queue:
					pending = append(pending, b)
				default:
					s.flush(pending)
					return
				}
			}
		}
	}
}

// part is one insert. token doubles as the spool file name and the
// insert_deduplication_token, so a direct insert that landed despite an
// error and its later replay count once.
type part struct {
	table string
	token string
	body  []byte
}

// flush writes blobs before requests, so a stored request never points at a
// missing blob, and replays the spool before new data to keep that order.
func (s *Sink) flush(pending []Batch) []Batch {
	if s.spooled {
		if err := s.replay(); err != nil {
			s.markDown(err)
			if len(pending) == 0 {
				return nil
			}
			return s.fail(pending, s.encode(pending), err)
		}
	}
	if len(pending) == 0 {
		return nil
	}
	parts := s.encode(pending)
	for i, p := range parts {
		if err := s.insert(p.table, p.body, p.token); err != nil {
			s.markDown(err)
			return s.fail(pending, parts[i:], err)
		}
	}
	s.markUp()
	s.stored.Add(int64(len(pending)))
	return nil
}

func (s *Sink) encode(pending []Batch) []part {
	var blobs, reqs bytes.Buffer
	be, re := json.NewEncoder(&blobs), json.NewEncoder(&reqs)
	be.SetEscapeHTML(false)
	re.SetEscapeHTML(false)
	for _, b := range pending {
		for _, row := range b.Blobs {
			_ = be.Encode(row)
		}
		_ = re.Encode(b.Request)
	}
	id := fmt.Sprintf("%019d-%06d", time.Now().UnixNano(), s.seq.Add(1)%1_000_000)
	var parts []part
	if blobs.Len() > 0 {
		parts = append(parts, part{"blobs", id + "-0-blobs", blobs.Bytes()})
	}
	return append(parts, part{"requests", id + "-1-requests", reqs.Bytes()})
}

// fail spools the parts not yet inserted. Without a spool (or if writing it
// fails) the batches stay in memory, and the oldest beyond QueueSize drop.
func (s *Sink) fail(pending []Batch, parts []part, cause error) []Batch {
	s.failed.Add(1)
	if s.cfg.SpoolDir != "" {
		err := s.spool(parts)
		if err == nil {
			s.spooledN.Add(int64(len(pending)))
			return nil
		}
		s.log("error", "recorder: spool write failed", map[string]any{"error": err.Error(), "cause": cause.Error()})
	}
	if over := len(pending) - s.cfg.QueueSize; over > 0 {
		s.dropped.Add(int64(over))
		for _, b := range pending[:over] {
			if b.OnDropped != nil {
				b.OnDropped()
			}
		}
		pending = pending[over:]
	}
	return pending
}

var errSpoolFull = errors.New("spool full")

// spool writes parts as <token>.ndjson, each fsynced and renamed
// into place, so a crash leaves either a whole file or none.
func (s *Sink) spool(parts []part) error {
	var size int64
	for _, p := range parts {
		size += int64(len(p.body))
	}
	if s.cfg.SpoolMaxBytes > 0 && s.spoolBytes+size > s.cfg.SpoolMaxBytes {
		return errSpoolFull
	}
	for _, p := range parts {
		name := filepath.Join(s.cfg.SpoolDir, p.token+".ndjson")
		if err := writeFileSync(name, p.body); err != nil {
			return err
		}
	}
	if d, err := os.Open(s.cfg.SpoolDir); err == nil {
		_ = d.Sync()
		d.Close()
	}
	s.spoolBytes += size
	s.spooled = true
	return nil
}

func writeFileSync(name string, body []byte) error {
	tmp := name + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(body); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, name)
}

// replay inserts spooled files oldest first and deletes each once ClickHouse
// confirms it. The file name is the dedup token.
func (s *Sink) replay() error {
	files, _ := s.spoolFiles()
	for _, f := range files {
		body, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		token := strings.TrimSuffix(filepath.Base(f), ".ndjson")
		table := token[strings.LastIndex(token, "-")+1:]
		if err := s.insert(table, body, token); err != nil {
			return err
		}
		os.Remove(f)
		s.spoolBytes -= int64(len(body))
		if table == "requests" {
			s.stored.Add(int64(bytes.Count(body, []byte("\n"))))
		}
	}
	if len(files) > 0 {
		s.log("info", "recorder: spool replayed", map[string]any{"files": len(files)})
	}
	s.spooled, s.spoolBytes = false, 0
	return nil
}

func (s *Sink) spoolFiles() ([]string, int64) {
	if s.cfg.SpoolDir == "" {
		return nil, 0
	}
	files, _ := filepath.Glob(filepath.Join(s.cfg.SpoolDir, "*.ndjson"))
	sort.Strings(files)
	var size int64
	for _, f := range files {
		if st, err := os.Stat(f); err == nil {
			size += st.Size()
		}
	}
	return files, size
}

func (s *Sink) markDown(err error) {
	if !s.down {
		s.down = true
		s.log("warn", "recorder: ClickHouse unavailable, spooling", map[string]any{"error": err.Error(), "spool": s.cfg.SpoolDir})
	}
}

func (s *Sink) markUp() {
	if s.down {
		s.down = false
		s.log("info", "recorder: ClickHouse back", nil)
	}
}

func (s *Sink) insert(table string, body []byte, token string) error {
	q := url.Values{}
	q.Set("query", fmt.Sprintf("INSERT INTO %s.%s FORMAT JSONEachRow", s.cfg.Database, table))
	q.Set("date_time_input_format", "best_effort")
	q.Set("input_format_skip_unknown_fields", "1")
	q.Set("wait_end_of_query", "1")
	if token != "" {
		q.Set("insert_deduplication_token", token)
	}
	req, err := http.NewRequest(http.MethodPost, s.cfg.URL+"/?"+q.Encode(), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("X-ClickHouse-User", s.cfg.User)
	req.Header.Set("X-ClickHouse-Key", s.cfg.Password)
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK || resp.Header.Get("X-ClickHouse-Exception-Code") != "" {
		return fmt.Errorf("%s: HTTP %d: %s", table, resp.StatusCode, bytes.TrimSpace(msg))
	}
	return nil
}
