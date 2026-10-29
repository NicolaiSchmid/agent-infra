// Package dedup splits a model request body into a small skeleton plus
// content-addressed blobs, so the history a coding agent resends on every
// turn is stored once.
//
// Claude Code resends the whole conversation, system prompt and tool
// definitions on every request; Codex over HTTP does the same with `input`.
// Each element of `messages`/`input` and the whole `system`, `instructions`
// and `tools` values become blobs keyed by the hash of their canonical JSON.
// The skeleton keeps everything else: whole values become {"$blob":"<hash>"}
// and a list becomes {"$refs":[start,end]}, a range of Refs, so the
// ever-growing message list is stored once (in Refs) rather than twice.
//
// Prompt-cache breakpoints (`cache_control`) move to the newest message on
// every turn, which would give the same message a different hash each time.
// They are lifted out before hashing and kept as patches (JSON pointer +
// value), so Join restores the request exactly, apart from object key order.
package dedup

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Blob is one deduplicated piece of a request.
type Blob struct {
	Hash    string
	Kind    string // system | instructions | tools | message
	Role    string
	Type    string
	Content []byte // canonical JSON
}

// Patch is a lifted cache_control value. Path is a JSON pointer to the object
// that held it.
type Patch struct {
	Path  string          `json:"path"`
	Value json.RawMessage `json:"value"`
}

// Split is the result of splitting one request.
type Split struct {
	Skeleton []byte
	Refs     []string // blob hashes in request order
	Blobs    []Blob
	Patches  []Patch
}

var wholeKeys = []string{"system", "instructions", "tools"}
var listKeys = []string{"messages", "input"}

// SplitRequest splits body. A body that is not a JSON object is returned as
// the skeleton unchanged.
func SplitRequest(body []byte) (Split, error) {
	doc, err := decode(body)
	if err != nil {
		return Split{Skeleton: body}, err
	}
	root, ok := doc.(map[string]any)
	if !ok {
		return Split{Skeleton: body}, nil
	}
	var s Split
	liftCacheControl(root, "", &s.Patches)
	seen := map[string]bool{}
	add := func(kind string, v any) (map[string]any, error) {
		content, err := encode(v)
		if err != nil {
			return nil, err
		}
		sum := sha256.Sum256(content)
		hash := hex.EncodeToString(sum[:16])
		s.Refs = append(s.Refs, hash)
		if !seen[hash] {
			seen[hash] = true
			b := Blob{Hash: hash, Kind: kind, Content: content}
			if m, ok := v.(map[string]any); ok {
				b.Role, _ = m["role"].(string)
				b.Type, _ = m["type"].(string)
			}
			s.Blobs = append(s.Blobs, b)
		}
		return map[string]any{"$blob": hash}, nil
	}
	for _, key := range wholeKeys {
		v, ok := root[key]
		if !ok || v == nil {
			continue
		}
		ref, err := add(key, v)
		if err != nil {
			return Split{Skeleton: body}, err
		}
		root[key] = ref
	}
	for _, key := range listKeys {
		list, ok := root[key].([]any)
		if !ok {
			continue
		}
		start := len(s.Refs)
		for _, item := range list {
			if _, err := add("message", item); err != nil {
				return Split{Skeleton: body}, err
			}
		}
		root[key] = RefRange(start, len(s.Refs))
	}
	if s.Skeleton, err = encode(root); err != nil {
		return Split{Skeleton: body}, err
	}
	return s, nil
}

// RefRange is the skeleton placeholder for refs[start:end].
func RefRange(start, end int) map[string][]int { return map[string][]int{"$refs": {start, end}} }

// Join rebuilds a request from its skeleton, refs, blobs (by hash) and
// patches.
func Join(skeleton []byte, refs []string, blobs map[string][]byte, patches []Patch) ([]byte, error) {
	doc, err := decode(skeleton)
	if err != nil {
		return nil, err
	}
	doc, err = resolve(doc, refs, blobs)
	if err != nil {
		return nil, err
	}
	for _, p := range patches {
		target, err := pointer(doc, p.Path)
		if err != nil {
			return nil, err
		}
		m, ok := target.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("patch %s: not an object", p.Path)
		}
		v, err := decode(p.Value)
		if err != nil {
			return nil, err
		}
		m["cache_control"] = v
	}
	return encode(doc)
}

func resolve(v any, refs []string, blobs map[string][]byte) (any, error) {
	switch t := v.(type) {
	case map[string]any:
		if hash, ok := t["$blob"].(string); ok && len(t) == 1 {
			raw, ok := blobs[hash]
			if !ok {
				return nil, fmt.Errorf("missing blob %s", hash)
			}
			return decode(raw)
		}
		if r, ok := t["$refs"].([]any); ok && len(t) == 1 && len(r) == 2 {
			start, err1 := r[0].(json.Number).Int64()
			end, err2 := r[1].(json.Number).Int64()
			if err1 != nil || err2 != nil || start < 0 || end > int64(len(refs)) || start > end {
				return nil, fmt.Errorf("bad $refs %v", r)
			}
			list := make([]any, 0, end-start)
			for _, h := range refs[start:end] {
				raw, ok := blobs[h]
				if !ok {
					return nil, fmt.Errorf("missing blob %s", h)
				}
				item, err := decode(raw)
				if err != nil {
					return nil, err
				}
				list = append(list, item)
			}
			return list, nil
		}
		for k, child := range t {
			r, err := resolve(child, refs, blobs)
			if err != nil {
				return nil, err
			}
			t[k] = r
		}
	case []any:
		for i, child := range t {
			r, err := resolve(child, refs, blobs)
			if err != nil {
				return nil, err
			}
			t[i] = r
		}
	}
	return v, nil
}

func liftCacheControl(v any, path string, out *[]Patch) {
	switch t := v.(type) {
	case map[string]any:
		if cc, ok := t["cache_control"]; ok {
			if raw, err := encode(cc); err == nil {
				*out = append(*out, Patch{Path: path, Value: raw})
				delete(t, "cache_control")
			}
		}
		for k, child := range t {
			liftCacheControl(child, path+"/"+escape(k), out)
		}
	case []any:
		for i, child := range t {
			liftCacheControl(child, path+"/"+strconv.Itoa(i), out)
		}
	}
}

func pointer(doc any, path string) (any, error) {
	if path == "" {
		return doc, nil
	}
	cur := doc
	for _, part := range strings.Split(path[1:], "/") {
		part = strings.NewReplacer("~1", "/", "~0", "~").Replace(part)
		switch t := cur.(type) {
		case map[string]any:
			cur = t[part]
		case []any:
			i, err := strconv.Atoi(part)
			if err != nil || i < 0 || i >= len(t) {
				return nil, fmt.Errorf("bad pointer %s", path)
			}
			cur = t[i]
		default:
			return nil, fmt.Errorf("bad pointer %s", path)
		}
	}
	return cur, nil
}

func escape(k string) string {
	return strings.NewReplacer("~", "~0", "/", "~1").Replace(k)
}

func decode(b []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	return v, nil
}

// encode is canonical: sorted keys (encoding/json sorts map keys), no HTML
// escaping, numbers kept verbatim.
func encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	e := json.NewEncoder(&buf)
	e.SetEscapeHTML(false)
	if err := e.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// Item hashes one value the way SplitRequest hashes each piece of a request:
// cache_control lifted out (patches are relative to the item), canonical
// JSON, sha256. Callers that already know a request's pieces (the backfill)
// build skeletons from these without re-splitting whole requests.
func Item(kind string, raw []byte) (Blob, []Patch, error) {
	v, err := decode(raw)
	if err != nil {
		return Blob{}, nil, err
	}
	var patches []Patch
	liftCacheControl(v, "", &patches)
	content, err := encode(v)
	if err != nil {
		return Blob{}, nil, err
	}
	sum := sha256.Sum256(content)
	b := Blob{Hash: hex.EncodeToString(sum[:16]), Kind: kind, Content: content}
	if m, ok := v.(map[string]any); ok {
		b.Role, _ = m["role"].(string)
		b.Type, _ = m["type"].(string)
	}
	return b, patches, nil
}

// Canonical is the encoding blobs are hashed over.
func Canonical(v any) ([]byte, error) { return encode(v) }
