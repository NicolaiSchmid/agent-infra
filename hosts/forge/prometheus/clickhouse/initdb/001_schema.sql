-- prometheus recorder schema. No TTL: everything is kept forever. Applied by the clickhouse image on first start
-- (empty data dir); every statement is idempotent, so re-applying is safe:
--   docker compose exec clickhouse clickhouse-client --multiquery < clickhouse/initdb/001_schema.sql

CREATE DATABASE IF NOT EXISTS prometheus;

-- Content-addressed request pieces: every message/input item, plus whole
-- system / instructions / tools values, stored once by sha256 of their
-- canonical JSON (cache_control lifted out, see recorder/internal/dedup).
CREATE TABLE IF NOT EXISTS prometheus.blobs
(
    hash       String,
    kind       LowCardinality(String),
    role       LowCardinality(String),
    type       LowCardinality(String),
    bytes      UInt32,
    content    String CODEC(ZSTD(6)),
    first_seen DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(first_seen)
ORDER BY hash
SETTINGS non_replicated_deduplication_window = 10000;

-- One row per model execution through the hub. The request is stored as a
-- skeleton with {"$blob": hash} placeholders; blob_refs lists them in order.
CREATE TABLE IF NOT EXISTS prometheus.requests
(
    ts                     DateTime64(3, 'UTC') CODEC(Delta, ZSTD(3)),
    request_id             String,
    trace_id               String,
    session_id             String,
    parent_session_id      String,
    harness                LowCardinality(String),
    user_agent             LowCardinality(String),
    originator             LowCardinality(String),
    client_ip              LowCardinality(String),
    client_key_hash        LowCardinality(String),
    source_format          LowCardinality(String),
    transport              LowCardinality(String),
    provider               LowCardinality(String),
    executor_type          LowCardinality(String),
    auth_id                LowCardinality(String),
    auth_index             LowCardinality(String),
    auth_type              LowCardinality(String),
    account                LowCardinality(String),
    model                  LowCardinality(String),
    requested_model        LowCardinality(String),
    alias                  LowCardinality(String),
    response_model         LowCardinality(String),
    reasoning_effort       LowCardinality(String),
    service_tier           LowCardinality(String),
    effective_service_tier LowCardinality(String),
    stream                 Bool,
    outcome                LowCardinality(String),
    status_code            UInt16,
    failed                 Bool,
    error                  String CODEC(ZSTD(3)),
    latency_ms             UInt32,
    ttft_ms                UInt32,
    input_tokens           UInt64,
    output_tokens          UInt64,
    reasoning_tokens       UInt64,
    cached_tokens          UInt64,
    cache_read_tokens      UInt64,
    cache_creation_tokens  UInt64,
    total_tokens           UInt64,
    request_headers        Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    response_headers       Map(LowCardinality(String), String) CODEC(ZSTD(3)),
    request_bytes          UInt32,
    new_blob_bytes         UInt32,
    skeleton               String CODEC(ZSTD(6)),
    blob_refs              Array(String) CODEC(ZSTD(6)),
    cache_control          String CODEC(ZSTD(3)),
    response               String CODEC(ZSTD(6)),
    response_bytes         UInt32,
    ws_events              String CODEC(ZSTD(6)),
    truncated              Bool,
    has_usage              Bool,
    has_completion         Bool,
    -- live | backfill:claude-request-log | backfill:claude-transcript | backfill:codex-rollout
    source                 LowCardinality(String) DEFAULT 'live',
    machine                LowCardinality(String),

    INDEX idx_session session_id TYPE bloom_filter(0.01) GRANULARITY 4,
    INDEX idx_request request_id TYPE bloom_filter(0.01) GRANULARITY 4
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (toDate(ts), harness, session_id, ts)
-- the recorder sends a fixed insert_deduplication_token per batch, so a
-- retry or spool replay of an insert that already landed stores nothing
SETTINGS non_replicated_deduplication_window = 10000;

-- T3 Code threads (from each machine's statev2.sqlite / state.sqlite, by the
-- backfill command), one row per (thread, native provider session). Join:
--   requests.session_id = t3_threads.native_session_id
--   (or requests.parent_session_id, for subagents)
CREATE TABLE IF NOT EXISTS prometheus.t3_threads
(
    machine           LowCardinality(String),
    thread_id         String,
    title             String,
    project_id        String,
    project_title     LowCardinality(String),
    workspace_root    String,
    provider          LowCardinality(String),
    native_session_id String,
    created_at        DateTime64(3, 'UTC'),
    updated_at        DateTime64(3, 'UTC'),
    archived          Bool,
    deleted           Bool
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (machine, thread_id, native_session_id);
