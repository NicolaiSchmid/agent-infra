package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"slices"
	"strings"
)

const (
	maxBodyBytes = 64 << 10
	maxRoutes    = 64
)

// Table is a project's whole routing table, as pushed and as stored.
type Table struct {
	Routes []Route `json:"routes"`
}

// Route sends requests for Host (and, optionally, paths starting with
// PathPrefix) to one target.
type Route struct {
	Host       string `json:"host"`
	PathPrefix string `json:"pathPrefix,omitempty"`
	Target     Target `json:"target"`
}

// Target is exactly one of a Convex deployment's origin ("cloud" for the
// API and WebSocket, "site" for HTTP actions) or an external HTTPS URL.
type Target struct {
	Convex string `json:"convex,omitempty"`
	Origin string `json:"origin,omitempty"`
	URL    string `json:"url,omitempty"`
}

// pathPrefix allows the unreserved and slash characters only, which keeps
// it safe inside a Traefik rule's backticks.
var pathPrefix = regexp.MustCompile(`^/[A-Za-z0-9._~/-]{0,127}$`)

// errForbidden marks a well-formed table that asks for something outside
// the project's registry entry.
var errForbidden = errors.New("forbidden")

// ValidationError lists every problem in a pushed table.
type ValidationError struct {
	Problems  []string
	Forbidden bool
}

func (e *ValidationError) Error() string { return strings.Join(e.Problems, "; ") }

// decodeTable parses a pushed body strictly: unknown fields and trailing
// data are errors.
func decodeTable(r io.Reader) (*Table, error) {
	dec := json.NewDecoder(r)
	dec.DisallowUnknownFields()
	var t Table
	if err := dec.Decode(&t); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}
	if dec.More() {
		return nil, errors.New("invalid JSON: trailing data after the table")
	}
	if t.Routes == nil {
		return nil, errors.New(`missing "routes" (send {"routes": []} to remove every route)`)
	}
	return &t, nil
}

// validate checks a table against the project's registry entry and
// normalises it (pathPrefix "/" is the same as none).
func validate(p Project, t *Table) error {
	v := &ValidationError{}
	add := func(err error, format string, args ...any) {
		v.Problems = append(v.Problems, fmt.Sprintf(format, args...))
		if errors.Is(err, errForbidden) {
			v.Forbidden = true
		}
	}
	if len(t.Routes) > maxRoutes {
		add(nil, "%d routes, at most %d allowed", len(t.Routes), maxRoutes)
		return v
	}
	seen := map[string]int{}
	for i := range t.Routes {
		r := &t.Routes[i]
		at := fmt.Sprintf("routes[%d]", i)
		if r.PathPrefix == "/" {
			r.PathPrefix = ""
		}
		switch {
		case !hostName.MatchString(r.Host) || len(r.Host) > 253:
			add(nil, "%s.host: %q is not a lowercase hostname", at, r.Host)
		case !p.allowsHost(r.Host):
			add(errForbidden, "%s.host: %s is not one of this project's hostnames", at, r.Host)
		}
		if r.PathPrefix != "" && !pathPrefix.MatchString(r.PathPrefix) {
			add(nil, "%s.pathPrefix: %q must start with / and use only A-Z a-z 0-9 . _ ~ / - (at most 128 characters)", at, r.PathPrefix)
		}
		key := r.Host + r.PathPrefix
		if j, dup := seen[key]; dup {
			add(nil, "%s: same host and pathPrefix as routes[%d]", at, j)
		} else {
			seen[key] = i
		}
		validateTarget(p, r.Target, at+".target", add)
	}
	if len(v.Problems) > 0 {
		return v
	}
	return nil
}

func validateTarget(p Project, t Target, at string, add func(error, string, ...any)) {
	switch {
	case t.Convex != "" && t.URL != "":
		add(nil, "%s: set either convex or url, not both", at)
	case t.Convex != "":
		if !slices.Contains(p.Convex, t.Convex) {
			add(errForbidden, "%s.convex: %q is not one of this project's deployments (%s)", at, t.Convex, strings.Join(p.Convex, ", "))
		}
		if t.Origin != "cloud" && t.Origin != "site" {
			add(nil, `%s.origin: must be "cloud" (API, WebSocket) or "site" (HTTP actions)`, at)
		}
	case t.URL != "":
		if t.Origin != "" {
			add(nil, "%s.origin: only for convex targets", at)
		}
		u, err := url.Parse(t.URL)
		switch {
		case err != nil || u.Scheme != "https" || u.Opaque != "" || u.User != nil:
			add(nil, "%s.url: must be https://<host>", at)
		case u.Port() != "" || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" || u.ForceQuery:
			add(nil, "%s.url: only scheme and host, no port, path, query or fragment", at)
		case !slices.Contains(p.Upstreams, u.Hostname()):
			add(errForbidden, "%s.url: %s is not one of this project's upstreams", at, u.Hostname())
		}
	default:
		add(nil, "%s: set convex (with origin) or url", at)
	}
}

// canonical is the stored form of a validated table.
func canonical(t *Table) []byte {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(t)
	return b.Bytes()
}
