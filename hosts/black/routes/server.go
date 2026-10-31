package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Server answers the routes API. Each project authenticates with its own
// key; the server only holds the keys' SHA-256 hashes.
type Server struct {
	registry *Registry
	hashes   map[string][]byte
	store    *Store
	log      *slog.Logger
	mu       sync.Mutex
}

// loadKeyHashes reads keysDir/<project>.sha256 (hex) for every project and
// fails if one is missing: a project without a key cannot be served.
func loadKeyHashes(keysDir string, r *Registry) (map[string][]byte, error) {
	hashes := map[string][]byte{}
	for project := range r.Projects {
		data, err := os.ReadFile(filepath.Join(keysDir, project+".sha256"))
		if err != nil {
			return nil, fmt.Errorf("key hash for %s: %w", project, err)
		}
		h, err := hex.DecodeString(strings.TrimSpace(string(data)))
		if err != nil || len(h) != sha256.Size {
			return nil, fmt.Errorf("key hash for %s: not a hex SHA-256", project)
		}
		hashes[project] = h
	}
	return hashes, nil
}

// restore renders every project's stored table again, so a restart or a
// registry change brings Traefik's files back in line. A stored table the
// registry no longer allows is left on disk but not rendered.
func (s *Server) restore() error {
	if err := s.store.prune(s.registry); err != nil {
		return err
	}
	for project, p := range s.registry.Projects {
		t, err := s.store.load(project)
		if err == nil {
			err = validate(p, t)
			if err != nil {
				s.log.Error("stored table no longer valid; not rendering it", "project", project, "error", err)
				t = &Table{Routes: []Route{}}
			}
			err = s.store.apply(project, t)
		}
		if err != nil {
			return fmt.Errorf("restore %s: %w", project, err)
		}
	}
	return nil
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /v1/projects/{project}/routes", s.authed(s.get))
	mux.HandleFunc("PUT /v1/projects/{project}/routes", s.authed(s.put))
	return mux
}

func (s *Server) authed(next func(http.ResponseWriter, *http.Request, string, Project)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("project")
		p, ok := s.registry.Projects[name]
		if !ok {
			writeError(w, http.StatusNotFound, fmt.Sprintf("unknown project %q", name))
			return
		}
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		sum := sha256.Sum256([]byte(token))
		if !ok || token == "" || subtle.ConstantTimeCompare(sum[:], s.hashes[name]) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="routes"`)
			writeError(w, http.StatusUnauthorized, "missing or wrong API key for this project")
			return
		}
		next(w, r, name, p)
	}
}

func (s *Server) get(w http.ResponseWriter, _ *http.Request, project string, _ Project) {
	s.mu.Lock()
	t, err := s.store.load(project)
	s.mu.Unlock()
	if err != nil {
		s.log.Error("load failed", "project", project, "error", err)
		writeError(w, http.StatusInternalServerError, "could not read the stored table")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(canonical(t))
}

func (s *Server) put(w http.ResponseWriter, r *http.Request, project string, p Project) {
	t, err := decodeTable(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("body larger than %d bytes", maxBodyBytes))
			return
		}
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := validate(p, t); err != nil {
		status := http.StatusBadRequest
		var v *ValidationError
		if errors.As(err, &v) && v.Forbidden {
			status = http.StatusForbidden
		}
		writeError(w, status, err.Error())
		return
	}
	body := canonical(t)
	sum := sha256.Sum256(body)
	hash := hex.EncodeToString(sum[:])[:16]

	s.mu.Lock()
	err = s.store.save(project, t)
	s.mu.Unlock()
	if err != nil {
		s.log.Error("save failed", "project", project, "error", err)
		writeError(w, http.StatusInternalServerError, "could not store the table")
		return
	}
	s.log.Info("routes accepted", "project", project, "routes", len(t.Routes), "hash", hash)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"project": project, "routes": len(t.Routes), "hash": hash})
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
