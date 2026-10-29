// Package sink batches rows into ClickHouse over its HTTP interface.
package sink

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	URL      string // e.g. http://127.0.0.1:8123
	User     string
	Password string
	Database string
	// QueueSize bounds buffered requests while ClickHouse is slow or down.
	QueueSize     int
	FlushInterval time.Duration
	BatchSize     int
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

	stored, failed, dropped atomic.Int64
}

func New(cfg Config, log Logger) *Sink {
	s := &Sink{
		cfg:    cfg,
		log:    log,
		client: &http.Client{Timeout: 30 * time.Second},
		queue:  make(chan Batch, cfg.QueueSize),
		done:   make(chan struct{}),
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

func (s *Sink) Stats() (stored, failed, dropped int64) {
	return s.stored.Load(), s.failed.Load(), s.dropped.Load()
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

// flush inserts blobs before requests, so a stored request never points at a
// missing blob. On failure the batch is kept for the next tick, up to the
// queue size; beyond that the oldest are dropped.
func (s *Sink) flush(pending []Batch) []Batch {
	if len(pending) == 0 {
		return nil
	}
	var blobs, reqs []any
	for _, b := range pending {
		blobs = append(blobs, b.Blobs...)
		reqs = append(reqs, b.Request)
	}
	err := s.insert("blobs", blobs)
	if err == nil {
		err = s.insert("requests", reqs)
	}
	if err != nil {
		s.failed.Add(1)
		s.log("warn", "recorder: ClickHouse insert failed, will retry", map[string]any{"error": err.Error(), "requests": len(pending)})
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
	s.stored.Add(int64(len(pending)))
	return nil
}

func (s *Sink) insert(table string, rows []any) error {
	if len(rows) == 0 {
		return nil
	}
	var body bytes.Buffer
	enc := json.NewEncoder(&body)
	enc.SetEscapeHTML(false)
	for _, r := range rows {
		if err := enc.Encode(r); err != nil {
			return err
		}
	}
	q := url.Values{}
	q.Set("query", fmt.Sprintf("INSERT INTO %s.%s FORMAT JSONEachRow", s.cfg.Database, table))
	q.Set("date_time_input_format", "best_effort")
	q.Set("input_format_skip_unknown_fields", "1")
	q.Set("wait_end_of_query", "1")
	req, err := http.NewRequest(http.MethodPost, s.cfg.URL+"/?"+q.Encode(), &body)
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
