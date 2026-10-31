package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Store keeps each project's last accepted table (stateDir/<project>.json)
// and its rendered Traefik file (dynamicDir/routes-<project>.yml).
type Store struct {
	stateDir   string
	dynamicDir string
}

func (s *Store) statePath(project string) string {
	return filepath.Join(s.stateDir, project+".json")
}

func (s *Store) dynamicPath(project string) string {
	return filepath.Join(s.dynamicDir, "routes-"+project+".yml")
}

// load returns the stored table, or an empty one if the project never pushed.
func (s *Store) load(project string) (*Table, error) {
	f, err := os.Open(s.statePath(project))
	if errors.Is(err, fs.ErrNotExist) {
		return &Table{Routes: []Route{}}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return decodeTable(f)
}

// save stores the table, then writes (or, when empty, removes) the Traefik
// file, each atomically.
func (s *Store) save(project string, t *Table) error {
	if err := writeAtomic(s.statePath(project), canonical(t)); err != nil {
		return err
	}
	return s.apply(project, t)
}

func (s *Store) apply(project string, t *Table) error {
	out := render(project, t)
	if out == nil {
		err := os.Remove(s.dynamicPath(project))
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	}
	return writeAtomic(s.dynamicPath(project), out)
}

// prune removes Traefik files of projects that left the registry.
func (s *Store) prune(r *Registry) error {
	files, err := filepath.Glob(filepath.Join(s.dynamicDir, "routes-*.yml"))
	if err != nil {
		return err
	}
	for _, f := range files {
		project := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "routes-"), ".yml")
		if _, ok := r.Projects[project]; !ok {
			if err := os.Remove(f); err != nil {
				return err
			}
		}
	}
	return nil
}

// writeAtomic writes through a temporary file in the same directory and a
// rename, so Traefik never reads half a file. The temporary name starts
// with a dot and does not end in .yml, so Traefik's watcher ignores it.
func writeAtomic(dst string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), dst); err != nil {
		return fmt.Errorf("rename into %s: %w", dst, err)
	}
	return nil
}
