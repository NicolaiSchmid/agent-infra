// Package rows holds the ClickHouse row types shared by the recorder plugin
// and the backfill command.
package rows

// Blob is a prometheus.blobs row.
type Blob struct {
	Hash      string `json:"hash"`
	Kind      string `json:"kind"`
	Role      string `json:"role"`
	Type      string `json:"type"`
	Bytes     int    `json:"bytes"`
	Content   string `json:"content"`
	FirstSeen string `json:"first_seen"`
}

// Request is a prometheus.requests row.
type Request struct {
	TS                   string            `json:"ts"`
	RequestID            string            `json:"request_id"`
	TraceID              string            `json:"trace_id"`
	SessionID            string            `json:"session_id"`
	ParentSessionID      string            `json:"parent_session_id"`
	Harness              string            `json:"harness"`
	UserAgent            string            `json:"user_agent"`
	Originator           string            `json:"originator"`
	ClientIP             string            `json:"client_ip"`
	ClientKeyHash        string            `json:"client_key_hash"`
	SourceFormat         string            `json:"source_format"`
	Transport            string            `json:"transport"`
	Provider             string            `json:"provider"`
	ExecutorType         string            `json:"executor_type"`
	AuthID               string            `json:"auth_id"`
	AuthIndex            string            `json:"auth_index"`
	AuthType             string            `json:"auth_type"`
	Account              string            `json:"account"`
	Model                string            `json:"model"`
	RequestedModel       string            `json:"requested_model"`
	Alias                string            `json:"alias"`
	ResponseModel        string            `json:"response_model"`
	ReasoningEffort      string            `json:"reasoning_effort"`
	ServiceTier          string            `json:"service_tier"`
	EffectiveServiceTier string            `json:"effective_service_tier"`
	Stream               bool              `json:"stream"`
	Outcome              string            `json:"outcome"`
	StatusCode           int               `json:"status_code"`
	Failed               bool              `json:"failed"`
	Error                string            `json:"error"`
	LatencyMS            int64             `json:"latency_ms"`
	TTFTMS               int64             `json:"ttft_ms"`
	InputTokens          int64             `json:"input_tokens"`
	OutputTokens         int64             `json:"output_tokens"`
	ReasoningTokens      int64             `json:"reasoning_tokens"`
	CachedTokens         int64             `json:"cached_tokens"`
	CacheReadTokens      int64             `json:"cache_read_tokens"`
	CacheCreationTokens  int64             `json:"cache_creation_tokens"`
	TotalTokens          int64             `json:"total_tokens"`
	RequestHeaders       map[string]string `json:"request_headers"`
	ResponseHeaders      map[string]string `json:"response_headers"`
	RequestBytes         int               `json:"request_bytes"`
	NewBlobBytes         int               `json:"new_blob_bytes"`
	Skeleton             string            `json:"skeleton"`
	BlobRefs             []string          `json:"blob_refs"`
	CacheControl         string            `json:"cache_control"`
	Response             string            `json:"response"`
	ResponseBytes        int               `json:"response_bytes"`
	WSEvents             string            `json:"ws_events"`
	Truncated            bool              `json:"truncated"`
	HasUsage             bool              `json:"has_usage"`
	HasCompletion        bool              `json:"has_completion"`
	// Source is "live" for the recorder plugin, "backfill:<kind>" for
	// requests rebuilt from local transcripts.
	Source  string `json:"source"`
	Machine string `json:"machine"`
}
