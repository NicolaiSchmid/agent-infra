// Command backfill rebuilds past Claude Code and Codex API calls from local
// transcripts and writes them to the recorder's ClickHouse tables, in the
// same shape as live rows (deduplicated skeleton + blobs), with source set
// to "backfill:<kind>". T3 Code threads go to prometheus.t3_threads, joined
// to requests on session_id = native_session_id.
//
//	CLICKHOUSE_PASSWORD=... backfill -machine atlas -client-ip 100.122.138.66 \
//	  -claude-dir ~/.claude/projects -codex-dir ~/.codex/sessions -t3-dir ~/.t3/userdata [-dry-run]
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"hash/fnv"
	"hash/maphash"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/dedup"
	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/rows"
	"github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/sink"
)

type piece struct {
	key string
	raw json.RawMessage
}

// call is one rebuilt model execution.
type call struct {
	source, requestID, sessionID, parentSessionID string
	harness, userAgent, originator, sourceFormat  string
	provider, model, responseModel, effort, cwd   string
	params                                        json.RawMessage
	whole                                         []piece
	listKey                                       string
	items                                         [][]byte // nil: unresolved
	unresolved                                    []string
	patches                                       []dedup.Patch
	response                                      []byte
	hasResponse                                   bool
	ts                                            time.Time
	ttft, latency                                 time.Duration
	notes                                         []string
	digest                                        string

	inputTokens, outputTokens, reasoningTokens, totalTokens int64
	cacheReadTokens, cacheCreationTokens, cachedTokens      int64
}

type stats struct {
	mu sync.Mutex
	m  map[string]int64
}

func (s *stats) add(k string, n int64) {
	s.mu.Lock()
	s.m[k] += n
	s.mu.Unlock()
}

type memoItem struct {
	blob    dedup.Blob
	patches []dedup.Patch
}

// builder turns calls into rows. One per file: messages repeat within a
// session, so items are hashed once per file.
type builder struct {
	seed maphash.Seed
	memo map[uint64]memoItem
}

func (b *builder) item(kind string, raw []byte) (memoItem, error) {
	k := maphash.Bytes(b.seed, append([]byte(kind), raw...))
	if m, ok := b.memo[k]; ok {
		return m, nil
	}
	bl, p, err := dedup.Item(kind, raw)
	if err != nil {
		return memoItem{}, err
	}
	m := memoItem{bl, p}
	b.memo[k] = m
	return m, nil
}

func (b *builder) build(c call, machine, clientIP string) (rows.Request, []dedup.Blob) {
	skel := map[string]any{}
	if len(c.params) > 0 {
		d := json.NewDecoder(bytes.NewReader(c.params))
		d.UseNumber()
		_ = d.Decode(&skel)
	}
	var refs []string
	var blobs []dedup.Blob
	patches := append([]dedup.Patch(nil), c.patches...)
	reqBytes := 0
	var notes []string
	addPatches := func(prefix string, ps []dedup.Patch) {
		for _, p := range ps {
			patches = append(patches, dedup.Patch{Path: prefix + p.Path, Value: p.Value})
		}
	}
	for _, w := range c.whole {
		m, err := b.item(w.key, w.raw)
		if err != nil {
			notes = append(notes, w.key+": "+err.Error())
			continue
		}
		skel[w.key] = map[string]string{"$blob": m.blob.Hash}
		refs = append(refs, m.blob.Hash)
		blobs = append(blobs, m.blob)
		addPatches("/"+w.key, m.patches)
		reqBytes += len(m.blob.Content)
	}
	listStart := len(refs)
	list := make([]any, 0, len(c.items))
	u := 0
	for i, raw := range c.items {
		if raw == nil {
			list = append(list, map[string]string{"$unresolved": c.unresolved[u]})
			u++
			continue
		}
		m, err := b.item("message", raw)
		if err != nil {
			list = append(list, map[string]string{"$unresolved": err.Error()})
			continue
		}
		list = append(list, map[string]string{"$blob": m.blob.Hash})
		refs = append(refs, m.blob.Hash)
		blobs = append(blobs, m.blob)
		addPatches(fmt.Sprintf("/%s/%d", c.listKey, i), m.patches)
		reqBytes += len(m.blob.Content)
	}
	if len(c.unresolved) == 0 && len(list) == len(refs)-listStart {
		skel[c.listKey] = dedup.RefRange(listStart, len(refs))
	} else {
		skel[c.listKey] = list
	}
	skeleton, _ := dedup.Canonical(skel)
	reqBytes += len(skeleton)
	if len(c.unresolved) > 0 {
		notes = append(notes, fmt.Sprintf("%d of %d messages unresolved", len(c.unresolved), len(c.items)))
	}
	notes = append(notes, c.notes...)

	model := c.model
	if model == "" {
		if m, ok := skel["model"].(string); ok {
			model = m
		}
	}
	row := rows.Request{
		TS: c.ts.UTC().Format(time.RFC3339Nano), RequestID: c.requestID, SessionID: c.sessionID,
		ParentSessionID: c.parentSessionID, Harness: c.harness, UserAgent: c.userAgent, Originator: c.originator,
		ClientIP: clientIP, SourceFormat: c.sourceFormat, Transport: "backfill", Provider: c.provider,
		Model: model, RequestedModel: model, ResponseModel: c.responseModel, ReasoningEffort: c.effort,
		Stream: true, LatencyMS: c.latency.Milliseconds(), TTFTMS: c.ttft.Milliseconds(),
		InputTokens: c.inputTokens, OutputTokens: c.outputTokens, ReasoningTokens: c.reasoningTokens,
		CachedTokens: c.cachedTokens, CacheReadTokens: c.cacheReadTokens, CacheCreationTokens: c.cacheCreationTokens,
		TotalTokens: c.totalTokens, RequestHeaders: map[string]string{}, ResponseHeaders: map[string]string{},
		RequestBytes: reqBytes, Skeleton: string(skeleton), BlobRefs: refs, Response: string(c.response),
		ResponseBytes: len(c.response), HasUsage: c.hasResponse, HasCompletion: c.hasResponse,
		Source: c.source, Machine: machine, Error: strings.Join(notes, "; "),
	}
	if row.BlobRefs == nil {
		row.BlobRefs = []string{}
	}
	if c.hasResponse {
		row.Outcome, row.StatusCode = "succeeded", 200
	} else {
		row.Outcome = "no_response"
	}
	if c.cwd != "" {
		row.RequestHeaders["x-backfill-cwd"] = c.cwd
	}
	if chunkLabel != "" {
		row.RequestHeaders["x-backfill-chunk"] = chunkLabel
	}
	if c.digest != "" {
		// match: the rebuilt request is byte-identical (canonically) to what
		// Claude Code sent, per its own requestDigest.
		row.RequestHeaders["x-backfill-digest"] = c.digest
	}
	if len(patches) > 0 {
		cc, _ := json.Marshal(patches)
		row.CacheControl = string(cc)
	}
	if row.LatencyMS < 0 {
		row.LatencyMS = 0
	}
	if row.TTFTMS < 0 {
		row.TTFTMS = 0
	}
	return row, blobs
}

type result struct {
	row   rows.Request
	blobs []dedup.Blob
}

func main() {
	machine := flag.String("machine", "", "machine name stored with every row (required)")
	clientIP := flag.String("client-ip", "", "tailnet IP stored as client_ip, to line up with live rows")
	claudeDir := flag.String("claude-dir", "", "Claude Code projects dir (~/.claude/projects)")
	codexDir := flag.String("codex-dir", "", "Codex sessions dir (~/.codex/sessions)")
	t3Dir := flag.String("t3-dir", "", "T3 Code userdata dir with statev2.sqlite")
	scope := flag.String("scope", "t3", "t3: only sessions of T3 threads; all: every session")
	sinceS := flag.String("since", "", "only calls at or after this RFC3339 time")
	untilS := flag.String("until", "", "only calls before this RFC3339 time (e.g. when live recording started)")
	dryRun := flag.Bool("dry-run", false, "parse and report, write nothing")
	limit := flag.Int("limit-files", 0, "stop after this many in-scope files (spike runs)")
	workers := flag.Int("workers", 4, "files parsed in parallel")
	verify := flag.Bool("verify", true, "check rebuilt Claude requests against their logged requestDigest")
	chURL := flag.String("clickhouse-url", "https://prometheus.takaya-buri.ts.net:8443", "ClickHouse HTTP URL")
	chUser := flag.String("clickhouse-user", "prometheus", "ClickHouse user (password: $CLICKHOUSE_PASSWORD or -clickhouse-password-file)")
	pwFile := flag.String("clickhouse-password-file", "", "file holding the ClickHouse password (keeps it out of argv/env)")
	shard := flag.Int("shard", 0, "with -shards: process only this shard (0-based) of the files")
	shards := flag.Int("shards", 1, "split the files into this many fixed shards (by path hash); rows carry request_headers['x-backfill-chunk'] = '<shard>/<shards>'")
	flag.Parse()
	if *machine == "" {
		log.Fatal("-machine is required")
	}
	verifyDigests = *verify
	if *shards < 1 || *shard < 0 || *shard >= *shards {
		log.Fatal("need 0 <= -shard < -shards")
	}
	chunkLabel = fmt.Sprintf("%d/%d", *shard, *shards)
	password := os.Getenv("CLICKHOUSE_PASSWORD")
	if *pwFile != "" {
		b, err := os.ReadFile(*pwFile)
		if err != nil {
			log.Fatal(err)
		}
		password = strings.TrimSpace(string(b))
	}
	var since, until time.Time
	if *sinceS != "" {
		since = parseTS(*sinceS)
	}
	if *untilS != "" {
		until = parseTS(*untilS)
	}
	st := &stats{m: map[string]int64{}}
	start := time.Now()

	var threads []t3Thread
	index := map[string]*t3Thread{}
	if *t3Dir != "" {
		var err error
		threads, index, err = loadT3(*t3Dir, *machine)
		if err != nil {
			log.Fatalf("t3: %v", err)
		}
		st.add("t3 threads", int64(len(threads)))
		st.add("t3 native sessions", int64(len(index)))
	}

	type job struct{ kind, path string }
	var jobs []job
	walk := func(kind, dir string) {
		if dir == "" {
			return
		}
		_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
			if err == nil && !d.IsDir() && strings.HasSuffix(p, ".jsonl") {
				jobs = append(jobs, job{kind, p})
			}
			return nil
		})
	}
	walk("claude", *claudeDir)
	walk("codex", *codexDir)
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].path < jobs[j].path })
	if *shards > 1 {
		// A file's shard depends only on its path, so a shard can be deleted
		// and rerun on its own.
		var mine []job
		for _, j := range jobs {
			h := fnv.New32a()
			h.Write([]byte(j.path))
			if int(h.Sum32()%uint32(*shards)) == *shard {
				mine = append(mine, j)
			}
		}
		jobs = mine
	}
	st.add("files", int64(len(jobs)))

	var sk *sink.Sink
	if !*dryRun {
		sk = sink.New(sink.Config{URL: strings.TrimRight(*chURL, "/"), User: *chUser, Password: password,
			Database: "prometheus", QueueSize: 1024, BatchSize: 200, FlushInterval: time.Second, Gzip: true},
			func(level, msg string, f map[string]any) { log.Printf("%s %s %v", level, msg, f) })
		if len(threads) > 0 {
			var rs []any
			for _, t := range threads {
				rs = append(rs, t)
			}
			if err := sk.Insert("t3_threads", rs, ""); err != nil {
				log.Fatalf("t3_threads: %v", err)
			}
		}
	}

	inScope := func(session string, heuristic bool) bool {
		if *scope == "all" {
			return true
		}
		return index[session] != nil || heuristic
	}

	results := make(chan result, 256)
	jobCh := make(chan job)
	var wg sync.WaitGroup
	var scoped sync.Mutex
	scopedFiles := 0
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobCh {
				b := &builder{seed: maphash.MakeSeed(), memo: map[uint64]memoItem{}}
				emit := func(c call) {
					if (!since.IsZero() && c.ts.Before(since)) || (!until.IsZero() && !c.ts.Before(until)) {
						st.add("calls outside window", 1)
						return
					}
					row, blobs := b.build(c, *machine, *clientIP)
					results <- result{row, blobs}
				}
				take := func() bool {
					scoped.Lock()
					defer scoped.Unlock()
					if *limit > 0 && scopedFiles >= *limit {
						return false
					}
					scopedFiles++
					return true
				}
				switch j.kind {
				case "claude":
					cf, err := readClaude(j.path)
					if err != nil {
						st.add("files failed", 1)
						log.Printf("%s: %v", j.path, err)
						continue
					}
					heur := cf.entrypoint == "sdk-ts" && strings.Contains(cf.cwd, "/.t3/")
					if !inScope("claude:"+cf.sessionID, heur) {
						st.add("files out of scope", 1)
						continue
					}
					if !take() {
						continue
					}
					st.add("claude files", 1)
					if len(cf.reqs) > 0 {
						st.add("claude files with request log", 1)
					}
					cf.emit(emit, st)
				case "codex":
					// Scope needs session_meta; check the head before parsing all.
					orig, tid := codexHead(j.path)
					if !inScope("codex:"+tid, strings.Contains(strings.ToLower(orig), "t3")) {
						st.add("files out of scope", 1)
						continue
					}
					if !take() {
						continue
					}
					st.add("codex files", 1)
					if _, err := readCodex(j.path, emit, st); err != nil {
						st.add("files failed", 1)
						log.Printf("%s: %v", j.path, err)
					}
				}
			}
		}()
	}
	go func() {
		for _, j := range jobs {
			jobCh <- j
		}
		close(jobCh)
		wg.Wait()
		close(results)
	}()

	seen := map[string]bool{}
	for r := range results {
		var fresh []any
		for _, bl := range r.blobs {
			if seen[bl.Hash] {
				continue
			}
			seen[bl.Hash] = true
			fresh = append(fresh, rows.Blob{Hash: bl.Hash, Kind: bl.Kind, Role: bl.Role, Type: bl.Type,
				Bytes: len(bl.Content), Content: string(bl.Content), FirstSeen: r.row.TS})
			st.add("blob bytes stored", int64(len(bl.Content)))
		}
		st.add("calls", 1)
		st.add("raw request bytes", int64(r.row.RequestBytes))
		st.add("skeleton bytes", int64(len(r.row.Skeleton)))
		st.add("response bytes", int64(r.row.ResponseBytes))
		if strings.Contains(r.row.Error, "unresolved") {
			st.add("calls with unresolved messages", 1)
		}
		if !r.row.HasUsage {
			st.add("calls without response", 1)
		}
		if sk != nil {
			sk.EnqueueWait(sink.Batch{Request: r.row, Blobs: fresh})
		}
	}
	if sk != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		sk.Close(ctx)
		cancel()
		stored, failed, dropped, _ := sk.Stats()
		st.add("stored", stored)
		st.add("failed inserts", failed)
		st.add("dropped", dropped)
	}
	keys := make([]string, 0, len(st.m))
	for k := range st.m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		v := st.m[k]
		if strings.HasSuffix(k, "bytes") || strings.HasSuffix(k, "bytes stored") {
			fmt.Printf("%-34s %10.1f MiB\n", k, float64(v)/(1<<20))
		} else {
			fmt.Printf("%-34s %10d\n", k, v)
		}
	}
	fmt.Printf("%-34s %10s\n", "elapsed", time.Since(start).Round(time.Second))
	// A chunk only counts as done if every call landed.
	if sk != nil && (st.m["stored"] != st.m["calls"] || st.m["dropped"] > 0 || st.m["files failed"] > 0) {
		fmt.Println("INCOMPLETE: stored != calls (or drops / failed files); delete this chunk and rerun it")
		os.Exit(2)
	}
}

// chunkLabel tags rows with their shard, so one chunk can be deleted.
var chunkLabel string

// codexHead reads session_meta from the first line.
func codexHead(path string) (originator, threadID string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	sc.Scan()
	line := sc.Bytes()
	var l struct {
		Payload struct {
			ID         string `json:"id"`
			Originator string `json:"originator"`
		} `json:"payload"`
	}
	_ = json.Unmarshal(line, &l)
	threadID = l.Payload.ID
	if threadID == "" {
		if m := threadIDRe.FindStringSubmatch(filepath.Base(path)); m != nil {
			threadID = m[1]
		}
	}
	return l.Payload.Originator, threadID
}
