package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
)

// Hook payloads, decoded with only the fields the recorder uses. The host
// serializes pluginapi structs with encoding/json (Go field names as keys,
// []byte as base64). Decoding request and response bodies into []byte goes
// through the generic string unquoting path, which was most of the hook cost
// on large requests; base64 has no escapes, so the raw token is decoded
// directly instead. Fields the recorder never stores, such as the translated
// upstream RequestBody, are left out and only scanned past.

type b64 []byte

func (b *b64) UnmarshalJSON(raw []byte) error {
	if len(raw) < 2 || raw[0] != '"' {
		*b = nil // null
		return nil
	}
	raw = raw[1 : len(raw)-1]
	out := make([]byte, base64.StdEncoding.DecodedLen(len(raw)))
	n, err := base64.StdEncoding.Decode(out, raw)
	if err != nil {
		return err
	}
	*b = out[:n]
	return nil
}

type wireResponse struct {
	RequestID       string
	SourceFormat    string
	Model           string
	Stream          bool
	RequestHeaders  http.Header
	ResponseHeaders http.Header
	OriginalRequest b64
	Body            b64
	StatusCode      int
}

type wireStreamChunk struct {
	RequestID       string
	SourceFormat    string
	Model           string
	RequestedModel  string
	RequestHeaders  http.Header
	ResponseHeaders http.Header
	OriginalRequest b64
	Body            b64
	ChunkIndex      int
}

type wireWebSocketEvent struct {
	RequestID      string
	SourceFormat   string
	Model          string
	RequestedModel string
	Payload        b64
}

var _ json.Unmarshaler = (*b64)(nil)

// cutB64 removes the base64 string value of top-level key from payload,
// replacing it with null, and returns it decoded. encoding/json writes keys
// as "Key":"value" with no whitespace, and base64 never contains a quote or
// backslash, so the value ends at the next quote. A quote inside any other
// string is escaped, so the pattern can only match a real key. Large bodies
// skip the JSON scanner this way: memchr instead of two full passes.
func cutB64(payload []byte, key string) (value []byte, rest []byte, err error) {
	pat := `"` + key + `":"`
	i := bytes.Index(payload, []byte(pat))
	if i < 0 {
		return nil, payload, nil
	}
	start := i + len(pat)
	n := bytes.IndexByte(payload[start:], '"')
	if n < 0 {
		return nil, payload, nil
	}
	raw := payload[start : start+n]
	value = make([]byte, base64.StdEncoding.DecodedLen(len(raw)))
	m, err := base64.StdEncoding.Decode(value, raw)
	if err != nil {
		return nil, payload, err
	}
	rest = make([]byte, 0, len(payload)-n+4)
	rest = append(rest, payload[:i+len(key)+3]...)
	rest = append(rest, "null"...)
	rest = append(rest, payload[start+n+1:]...)
	return value[:m], rest, nil
}

// decodeLarge cuts the named base64 fields, decodes the remainder into v and
// returns the cut values in order. Fields listed in drop are cut and
// discarded.
func decodeLarge(payload []byte, v any, keep []string, drop []string) ([][]byte, error) {
	out := make([][]byte, len(keep))
	var err error
	for i, k := range keep {
		if out[i], payload, err = cutB64(payload, k); err != nil {
			return nil, err
		}
	}
	for _, k := range drop {
		if _, payload, err = cutB64(payload, k); err != nil {
			return nil, err
		}
	}
	return out, json.Unmarshal(payload, v)
}
