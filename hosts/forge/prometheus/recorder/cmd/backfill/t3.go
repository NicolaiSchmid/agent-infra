package main

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// T3 Code keeps its threads in <userdata>/statev2.sqlite (and, for threads
// from before the v2 migration, state.sqlite). Each thread maps to native
// provider sessions: a Claude Code session id or a Codex thread id, the
// same ids the transcripts are named after. Opened read-only; T3 can keep
// running.

type t3Thread struct {
	Machine         string `json:"machine"`
	ThreadID        string `json:"thread_id"`
	Title           string `json:"title"`
	ProjectID       string `json:"project_id"`
	ProjectTitle    string `json:"project_title"`
	WorkspaceRoot   string `json:"workspace_root"`
	Provider        string `json:"provider"`
	NativeSessionID string `json:"native_session_id"`
	CreatedAt       string `json:"created_at"`
	UpdatedAt       string `json:"updated_at"`
	Archived        bool   `json:"archived"`
	Deleted         bool   `json:"deleted"`
}

func openRO(path string) (*sql.DB, error) {
	if _, err := os.Stat(path); err != nil {
		return nil, err
	}
	return sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(10000)")
}

// loadT3 returns one row per (thread, native session), plus threads without
// a known native session, and an index from "claude:<id>"/"codex:<id>" to
// the thread.
func loadT3(dir, machine string) ([]t3Thread, map[string]*t3Thread, error) {
	v2, err := openRO(filepath.Join(dir, "statev2.sqlite"))
	if err != nil {
		return nil, nil, err
	}
	defer v2.Close()

	projects := map[string][2]string{}
	if rs, err := v2.Query(`SELECT project_id, coalesce(title,''), coalesce(workspace_root,'') FROM projection_projects`); err == nil {
		for rs.Next() {
			var id, title, root string
			if rs.Scan(&id, &title, &root) == nil {
				projects[id] = [2]string{title, root}
			}
		}
		rs.Close()
	}

	threads := map[string]*t3Thread{}
	rs, err := v2.Query(`SELECT thread_id, coalesce(project_id,''), coalesce(title,''), coalesce(default_provider,''),
		coalesce(created_at,''), coalesce(updated_at,''), archived_at IS NOT NULL, deleted_at IS NOT NULL
		FROM orchestration_v2_projection_threads`)
	if err != nil {
		return nil, nil, fmt.Errorf("threads: %w", err)
	}
	for rs.Next() {
		t := &t3Thread{Machine: machine}
		if err := rs.Scan(&t.ThreadID, &t.ProjectID, &t.Title, &t.Provider, &t.CreatedAt, &t.UpdatedAt, &t.Archived, &t.Deleted); err != nil {
			rs.Close()
			return nil, nil, err
		}
		for _, ts := range []*string{&t.CreatedAt, &t.UpdatedAt} {
			if *ts == "" {
				*ts = "1970-01-01T00:00:00Z"
			}
		}
		p := projects[t.ProjectID]
		t.ProjectTitle, t.WorkspaceRoot = p[0], p[1]
		threads[t.ThreadID] = t
	}
	rs.Close()

	type native struct{ thread, key string }
	var natives []native
	add := func(thread, provider, id string) {
		if id == "" {
			return
		}
		prefix := "claude:"
		if provider == "codex" {
			prefix = "codex:"
		}
		natives = append(natives, native{thread, prefix + id})
	}
	if rs, err := v2.Query(`SELECT thread_id, provider, coalesce(json_extract(payload_json, '$.nativeThreadRef.nativeId'), '')
		FROM orchestration_v2_projection_provider_threads`); err == nil {
		for rs.Next() {
			var th, prov, id string
			if rs.Scan(&th, &prov, &id) == nil {
				add(th, prov, id)
			}
		}
		rs.Close()
	}
	if v1, err := openRO(filepath.Join(dir, "state.sqlite")); err == nil {
		if rs, err := v1.Query(`SELECT thread_id, provider_name,
			coalesce(json_extract(resume_cursor_json, '$.resume'), json_extract(resume_cursor_json, '$.threadId'), '')
			FROM provider_session_runtime`); err == nil {
			for rs.Next() {
				var th, prov, id string
				if rs.Scan(&th, &prov, &id) == nil {
					add(th, prov, id)
				}
			}
			rs.Close()
		}
		v1.Close()
	}

	index := map[string]*t3Thread{}
	var out []t3Thread
	mapped := map[string]bool{}
	for _, n := range natives {
		t, ok := threads[n.thread]
		if !ok || index[n.key] != nil {
			continue
		}
		row := *t
		row.NativeSessionID = n.key
		out = append(out, row)
		index[n.key] = &out[len(out)-1]
		mapped[n.thread] = true
	}
	for id, t := range threads {
		if !mapped[id] {
			out = append(out, *t)
		}
	}
	// out may have grown; rebuild the index on the final slice.
	index = map[string]*t3Thread{}
	for i := range out {
		if out[i].NativeSessionID != "" {
			index[out[i].NativeSessionID] = &out[i]
		}
	}
	return out, index, nil
}
