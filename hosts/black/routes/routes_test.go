package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata/")

var testRegistry = &Registry{Projects: map[string]Project{
	"modus-gateway": {
		Hosts:     []string{"gateway.modusservice.com", "*.preview.modusservice.com"},
		Convex:    []string{"modus-gateway-dev", "modus-gateway-prod"},
		Upstreams: []string{"modus-gateway.vercel.app"},
	},
	"modus": {
		Hosts:  []string{"modus.example"},
		Convex: []string{"modus-dev", "modus-prod"},
	},
}}

const goodTable = `{"routes": [
  {"host": "gateway.modusservice.com", "pathPrefix": "/v1", "target": {"convex": "modus-gateway-prod", "origin": "site"}},
  {"host": "gateway.modusservice.com", "pathPrefix": "/v1/models", "target": {"convex": "modus-gateway-prod", "origin": "cloud"}},
  {"host": "gateway.modusservice.com", "target": {"url": "https://modus-gateway.vercel.app"}},
  {"host": "pr-12.preview.modusservice.com", "pathPrefix": "/", "target": {"convex": "modus-gateway-dev", "origin": "site"}}
]}`

func mustDecode(t *testing.T, body string) *Table {
	t.Helper()
	tab, err := decodeTable(strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return tab
}

func TestValidateAccepts(t *testing.T) {
	tab := mustDecode(t, goodTable)
	if err := validate(testRegistry.Projects["modus-gateway"], tab); err != nil {
		t.Fatal(err)
	}
	if tab.Routes[3].PathPrefix != "" {
		t.Errorf("pathPrefix / not normalised: %q", tab.Routes[3].PathPrefix)
	}
	if err := validate(testRegistry.Projects["modus"], mustDecode(t, `{"routes": []}`)); err != nil {
		t.Fatal(err)
	}
}

func TestValidateRejects(t *testing.T) {
	cases := []struct {
		name, route string
		forbidden   bool
		want        string
	}{
		{"other project's host", `{"host": "modus.example", "target": {"convex": "modus-gateway-prod", "origin": "site"}}`, true, "not one of this project's hostnames"},
		{"wildcard two labels deep", `{"host": "a.b.preview.modusservice.com", "target": {"convex": "modus-gateway-dev", "origin": "site"}}`, true, "hostnames"},
		{"wildcard apex", `{"host": "preview.modusservice.com", "target": {"convex": "modus-gateway-dev", "origin": "site"}}`, true, "hostnames"},
		{"uppercase host", `{"host": "Gateway.modusservice.com", "target": {"convex": "modus-gateway-prod", "origin": "site"}}`, false, "lowercase hostname"},
		{"rule injection in host", "{\"host\": \"gateway.modusservice.com`) || Host(`x.com\", \"target\": {\"convex\": \"modus-gateway-prod\", \"origin\": \"site\"}}", false, "lowercase hostname"},
		{"rule injection in path", "{\"host\": \"gateway.modusservice.com\", \"pathPrefix\": \"/a`) || PathPrefix(`/\", \"target\": {\"convex\": \"modus-gateway-prod\", \"origin\": \"site\"}}", false, "pathPrefix"},
		{"relative path", `{"host": "gateway.modusservice.com", "pathPrefix": "v1", "target": {"convex": "modus-gateway-prod", "origin": "site"}}`, false, "pathPrefix"},
		{"other project's deployment", `{"host": "gateway.modusservice.com", "target": {"convex": "modus-prod", "origin": "site"}}`, true, "not one of this project's deployments"},
		{"bad origin", `{"host": "gateway.modusservice.com", "target": {"convex": "modus-gateway-prod", "origin": "admin"}}`, false, "origin"},
		{"both targets", `{"host": "gateway.modusservice.com", "target": {"convex": "modus-gateway-prod", "origin": "site", "url": "https://modus-gateway.vercel.app"}}`, false, "not both"},
		{"no target", `{"host": "gateway.modusservice.com", "target": {}}`, false, "set convex"},
		{"http upstream", `{"host": "gateway.modusservice.com", "target": {"url": "http://modus-gateway.vercel.app"}}`, false, "https"},
		{"upstream with path", `{"host": "gateway.modusservice.com", "target": {"url": "https://modus-gateway.vercel.app/x"}}`, false, "no port, path"},
		{"upstream with port", `{"host": "gateway.modusservice.com", "target": {"url": "https://modus-gateway.vercel.app:8443"}}`, false, "no port"},
		{"upstream with userinfo", `{"host": "gateway.modusservice.com", "target": {"url": "https://u:p@modus-gateway.vercel.app"}}`, false, "https://<host>"},
		{"unknown upstream", `{"host": "gateway.modusservice.com", "target": {"url": "https://evil.example"}}`, true, "not one of this project's upstreams"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := validate(testRegistry.Projects["modus-gateway"], mustDecode(t, `{"routes": [`+c.route+`]}`))
			v, ok := err.(*ValidationError)
			if !ok {
				t.Fatalf("got %v, want a ValidationError", err)
			}
			if v.Forbidden != c.forbidden || !strings.Contains(v.Error(), c.want) {
				t.Errorf("got forbidden=%v %q, want forbidden=%v containing %q", v.Forbidden, v.Error(), c.forbidden, c.want)
			}
		})
	}
}

func TestValidateLimits(t *testing.T) {
	p := testRegistry.Projects["modus-gateway"]
	route := `{"host": "gateway.modusservice.com", "target": {"url": "https://modus-gateway.vercel.app"}}`
	if err := validate(p, mustDecode(t, `{"routes": [`+route+`,`+route+`]}`)); err == nil || !strings.Contains(err.Error(), "same host and pathPrefix") {
		t.Errorf("duplicate route: got %v", err)
	}
	many := strings.TrimSuffix(strings.Repeat(route+",", maxRoutes+1), ",")
	if err := validate(p, mustDecode(t, `{"routes": [`+many+`]}`)); err == nil || !strings.Contains(err.Error(), "at most") {
		t.Errorf("too many routes: got %v", err)
	}
}

func TestDecodeStrict(t *testing.T) {
	for _, body := range []string{
		`{}`,
		`{"routes": [], "extra": 1}`,
		`{"routes": [{"host": "a.b", "target": {}, "middlewares": ["x"]}]}`,
		`{"routes": []} {"routes": []}`,
		`not json`,
	} {
		if _, err := decodeTable(strings.NewReader(body)); err == nil {
			t.Errorf("%s: accepted", body)
		}
	}
}

func TestRenderGolden(t *testing.T) {
	tab := mustDecode(t, goodTable)
	if err := validate(testRegistry.Projects["modus-gateway"], tab); err != nil {
		t.Fatal(err)
	}
	got := render("modus-gateway", tab)
	golden := filepath.Join("testdata", "routes-modus-gateway.yml")
	if *update {
		if err := os.WriteFile(golden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Errorf("render differs from %s (go test -update):\n%s", golden, got)
	}
	if render("modus", &Table{Routes: []Route{}}) != nil {
		t.Error("an empty table renders a file")
	}
}

func TestRegistryCheck(t *testing.T) {
	dup := &Registry{Projects: map[string]Project{
		"a": {Hosts: []string{"x.example"}},
		"b": {Hosts: []string{"x.example"}},
	}}
	if err := dup.check(); err == nil {
		t.Error("a host claimed twice passed")
	}
	if err := testRegistry.check(); err != nil {
		t.Error(err)
	}
}

const testKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func newTestServer(t *testing.T) (*Server, string, string) {
	t.Helper()
	state, dynamic := t.TempDir(), t.TempDir()
	sum := sha256.Sum256([]byte(testKey))
	other := sha256.Sum256([]byte("another key"))
	s := &Server{
		registry: testRegistry,
		hashes:   map[string][]byte{"modus-gateway": sum[:], "modus": other[:]},
		store:    &Store{stateDir: state, dynamicDir: dynamic},
		log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	if err := s.restore(); err != nil {
		t.Fatal(err)
	}
	return s, state, dynamic
}

func do(t *testing.T, h http.Handler, method, path, key, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestServer(t *testing.T) {
	s, _, dynamic := newTestServer(t)
	h := s.routes()
	path := "/v1/projects/modus-gateway/routes"
	file := filepath.Join(dynamic, "routes-modus-gateway.yml")

	if rec := do(t, h, "PUT", path, "", goodTable); rec.Code != http.StatusUnauthorized {
		t.Errorf("no key: %d", rec.Code)
	}
	if rec := do(t, h, "PUT", path, "another key", goodTable); rec.Code != http.StatusUnauthorized {
		t.Errorf("another project's key: %d", rec.Code)
	}
	if rec := do(t, h, "PUT", "/v1/projects/nope/routes", testKey, goodTable); rec.Code != http.StatusNotFound {
		t.Errorf("unknown project: %d", rec.Code)
	}
	if rec := do(t, h, "PUT", path, testKey, `{"routes": [{"host": "modus.example", "target": {"convex": "modus-gateway-prod", "origin": "site"}}]}`); rec.Code != http.StatusForbidden {
		t.Errorf("foreign host: %d %s", rec.Code, rec.Body)
	}
	if rec := do(t, h, "PUT", path, testKey, `{"routes": [`+strings.Repeat(" ", maxBodyBytes)+`]}`); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("large body: %d", rec.Code)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("a rejected push wrote a file")
	}

	rec := do(t, h, "PUT", path, testKey, goodTable)
	if rec.Code != http.StatusOK {
		t.Fatalf("good push: %d %s", rec.Code, rec.Body)
	}
	want, _ := os.ReadFile(filepath.Join("testdata", "routes-modus-gateway.yml"))
	if got, _ := os.ReadFile(file); string(got) != string(want) {
		t.Errorf("rendered file differs from the golden file:\n%s", got)
	}

	rec = do(t, h, "GET", path, testKey, "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"pathPrefix": "/v1/models"`) {
		t.Errorf("get: %d %s", rec.Code, rec.Body)
	}

	// A restart re-renders the stored table.
	os.Remove(file)
	if err := s.restore(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(file); err != nil {
		t.Errorf("restore did not re-render: %v", err)
	}

	if rec := do(t, h, "PUT", path, testKey, `{"routes": []}`); rec.Code != http.StatusOK {
		t.Fatalf("empty push: %d", rec.Code)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Error("an empty table left the file")
	}
}

func TestRestorePrunesRemovedProjects(t *testing.T) {
	_, _, dynamic := newTestServer(t)
	stale := filepath.Join(dynamic, "routes-gone.yml")
	os.WriteFile(stale, []byte("{}"), 0o644)
	custom := filepath.Join(dynamic, "custom-domains.yml")
	os.WriteFile(custom, []byte("{}"), 0o644)
	s := &Server{registry: testRegistry, store: &Store{stateDir: t.TempDir(), dynamicDir: dynamic}, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := s.restore(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("file of a removed project kept")
	}
	if _, err := os.Stat(custom); err != nil {
		t.Error("restore removed a file it does not own")
	}
}

func TestKeyHashes(t *testing.T) {
	dir := t.TempDir()
	sum := sha256.Sum256([]byte(testKey))
	os.WriteFile(filepath.Join(dir, "modus-gateway.sha256"), []byte(hex.EncodeToString(sum[:])+"\n"), 0o400)
	if _, err := loadKeyHashes(dir, testRegistry); err == nil {
		t.Error("a missing key hash passed")
	}
	os.WriteFile(filepath.Join(dir, "modus.sha256"), []byte(hex.EncodeToString(sum[:])), 0o400)
	if _, err := loadKeyHashes(dir, testRegistry); err != nil {
		t.Error(err)
	}
}
