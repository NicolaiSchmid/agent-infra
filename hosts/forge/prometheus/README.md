# prometheus

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) hub that holds the
Claude and Codex subscription logins and exposes them as one API endpoint on
the tailnet: `https://prometheus.takaya-buri.ts.net`. Pattern from
[Theo's gist](https://gist.github.com/t3dotgg/59a521d2ee8d70aaf90e280c175072af).

## Why here

- **forge-linux Lima VM** — residential egress (wilhelm.tel), and the VM is a
  system daemon, so it comes back while forge sits at the login window after a
  reboot (the macOS Tailscale app and LaunchAgents don't).
- **Own Tailscale node** (`tag:prometheus`) — clients point at the service
  name, not the machine. Moving the hub later = move this stack + ts-state.
- atlas/black egress from Hetzner (AS24940); tower is unstable.

## Layout (inside forge-linux)

| Path | What |
|------|------|
| `~/prometheus/` | checkout of this directory (`docker compose` runs here) |
| `/opt/prometheus/config.yaml` | real config (secrets; from `config.example.yaml`) |
| `/opt/prometheus/auths/` | OAuth credentials, one JSON per account |
| `/opt/prometheus/ts-state/` | Tailscale node state |
| `/opt/prometheus/logs/` | proxy logs |
| `/opt/prometheus/usage/` | usage-statistics plugin SQLite (`usage.db`) |
| `/opt/prometheus/clickhouse/` | ClickHouse data (recorder plugin) |
| `/opt/prometheus/recorder-spool/` | recorder batches waiting for ClickHouse |
| `/opt/prometheus/keys.env` | access, management and ClickHouse keys |

## Install

```bash
ssh nschmid10049@forge
limactl shell forge-linux
sudo apt-get install -y docker-compose-plugin   # once
sudo install -d -o "$USER" /opt/prometheus /opt/prometheus/{auths,ts-state,logs,clickhouse,recorder-spool}
# copy config.example.yaml → /opt/prometheus/config.yaml, fill the keys (chmod 600)
# put TS_AUTHKEY (optional) and CLICKHOUSE_PASSWORD in ~/prometheus/.env (chmod 600)
cd ~/prometheus && docker compose up -d
```

Check: `curl -s https://prometheus.takaya-buri.ts.net/v1/models -H "Authorization: Bearer <access key>" | head -c 300`.
Panel: `https://prometheus.takaya-buri.ts.net/management.html` (management key).

## Plugins

Baked into the image by `Dockerfile`, pinned by version + sha256 (plugins run
in-process and see every credential, so review the source before bumping):

- [usage-statistics](https://github.com/Fwindy/cpa-usage-statistics) v0.2.0 —
  per-request tokens/latency/TTFT/failures in `/opt/prometheus/usage/usage.db`.
  Query: `GET /v0/management/plugins/usage-statistics/usage?start=<RFC3339>&end=<RFC3339>`
  (management key). Enabled via `plugins:` in `config.yaml`.

- [Fwindy panel](https://github.com/Fwindy/Cli-Proxy-API-Management-Center)
  `v20261028-build1` — management UI with usage/cost pages for the plugin.
  Baked in at `/CLIProxyAPI/static/management.html`; `disable-auto-update-panel: true`
  because the fork auto-publishes upstream merges every 6 h. Reviewed 2026-10-27:
  same-origin API only, extra fetch only to models.dev on "sync prices".

- **recorder** (`recorder/`, ours) — writes every request, its full request
  and response bodies, and its usage record to ClickHouse. See below.

After changing the Dockerfile: `docker compose build && docker compose up -d cli-proxy-api`.

## Request log (recorder + ClickHouse)

The `recorder` plugin hooks the proxy's request/response/stream/usage
callbacks and writes one row per model execution to `prometheus.requests`:
tokens (input, cache read/write, reasoning, output), account, model, session,
harness, client tailnet IP, latency/TTFT, status, sanitized headers
(rate-limit headers included, credentials dropped), the full response (SSE as
sent to the client) and the request.

Requests are deduplicated. Claude Code resends the whole conversation, system
prompt and tool definitions on every turn, so each `messages`/`input` item and
the whole `system`/`instructions`/`tools` values go to `prometheus.blobs` once,
keyed by the sha256 of their canonical JSON. The request row keeps a skeleton
with `{"$blob": hash}` for whole values and `{"$refs": [start, end]}` (a
range of `blob_refs`) for the message list, so the growing history is stored
once per row rather than twice. `cache_control`
breakpoints move to the newest message every turn, so they are lifted out
before hashing and kept in `cache_control` (JSON-pointer patches);
`recorder/internal/dedup.Join` rebuilds the exact request (key order aside).
Spike numbers (short sessions): 3–9× from dedup, ~11× on disk with ZSTD;
the ratio grows with session length.

ClickHouse binds to loopback in the shared netns; the tailnet reaches it at
`https://prometheus.takaya-buri.ts.net:8443` (HTTP interface, user
`prometheus`, password `CLICKHOUSE_PASSWORD` in `/opt/prometheus/keys.env`).

```bash
curl -s https://prometheus.takaya-buri.ts.net:8443/ -H "X-ClickHouse-User: prometheus" \
  -H "X-ClickHouse-Key: $PW" --data-binary @- <<'SQL'
-- cache hit ratio per harness/model
SELECT harness, model, count() req,
       round(sum(cache_read_tokens) / sum(input_tokens + cache_read_tokens + cache_creation_tokens), 3) cache_hit
FROM prometheus.requests GROUP BY 1, 2;
SQL
```

```sql
-- tool calls (Claude tool_use blocks)
SELECT JSONExtractString(c, 'name') tool, count() calls
FROM (SELECT arrayJoin(JSONExtractArrayRaw(content, 'content')) c
      FROM prometheus.blobs FINAL WHERE role = 'assistant')
WHERE JSONExtractString(c, 'type') = 'tool_use' GROUP BY tool ORDER BY calls DESC;

-- messages of one request, in order
SELECT b.role, b.type, b.content
FROM (SELECT arrayJoin(arrayEnumerate(blob_refs)) i, blob_refs[i] hash
      FROM prometheus.requests WHERE request_id = '<id>') r
JOIN prometheus.blobs b USING hash ORDER BY i;
```

Notes:

- Bodies contain whatever the agents saw: file contents, pasted secrets. The
  database is as sensitive as `auths/`.
- Codex over websocket sends only the new input items per turn and chains
  turns with `previous_response_id` (in the skeleton); follow that chain to
  get the whole conversation.
- Usage records carry their own RequestID; they are paired with hook data by
  TraceID, oldest first (a Codex websocket carries several turns per trace).
- Retention: none. Everything is kept forever; watch disk on the VM
  (`SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active`).
- ClickHouse down: batches go to `/opt/prometheus/recorder-spool` (fsynced,
  capped at `spool-max-mb`, default 10 GiB) and replay in order once it's
  back, also across proxy restarts. Each insert carries a fixed
  `insert_deduplication_token` (tables have `non_replicated_deduplication_window`),
  so an insert that landed before its connection dropped isn't stored twice.
  Tested live by stopping ClickHouse mid-traffic: 52 files spooled, replayed,
  no duplicates, no gaps.
- Cost: hooks only copy bytes on the request path; dedup and encoding run on
  a background worker. Large base64 bodies are cut out of the hook payload
  with a byte search instead of the JSON scanner (`wire.go`). Benchmark on
  forge with a real 1.3 MB Claude request (p99 is 0.8 MB): hooks 6 ms
  (incl. the host's marshalling; decoding the body once is 6 ms),
  background 16 ms. Live on forge (2026-10-29, 57 requests, avg 404 KB):
  15.8 ms of hook time per request summed over all its calls (longest single
  call 8.4 ms, so at most that much added before the first byte), 10.8 ms
  worker; the whole proxy used ~220 ms CPU per request and 2% of one core.
  The plugin logs `recorder: stats` (hook/worker ms per request) every 5 min. Re-run: `RECORDER_BENCH_DIR=<dir with body.json,
  resp.sse> go test -run x -bench .` in `recorder/`.
- The dedup cache is in memory: after a proxy restart, each live session's
  first request writes its history again (collapsed by ReplacingMergeTree).
- Schema: `clickhouse/initdb/001_schema.sql`, applied on first start only.
  New columns need an `ALTER TABLE` on the live database.

## Backfill (history from before the recorder)

`recorder/cmd/backfill` rebuilds past API calls from each machine's local
transcripts and writes them into the same tables, with `source` set to the
kind of reconstruction and `machine` set:

| `source` | From | Fidelity |
|---|---|---|
| `backfill:claude-request-log` | Claude Code ≥ 2.1.281 `api-request` records (params, system + tools shape, base/keep/tail message hashes, cache_control paths) | exact: `request_headers['x-backfill-digest'] = 'match'` when the rebuild reproduces Claude Code's own `requestDigest` (~85% on the Mac; the rest have every message hash-verified but differ somewhere in the envelope) |
| `backfill:claude-transcript` | older Claude Code: parentUuid chain of user/assistant lines | messages only, no system prompt or tools |
| `backfill:codex-rollout` | Codex rollouts: each `token_count` closes a model call; earlier items are its input | full input + instructions, no tool definitions |

Usage (tokens, cache read/write) comes from the transcripts; latency is
approximate (line timestamps). T3 Code threads (title, project, native
session ids) go to `prometheus.t3_threads`; join on
`requests.session_id = t3_threads.native_session_id`. Default scope is T3
sessions only (mapped through the T3 databases, or T3 worktree cwd /
`t3code` originator); `-scope all` takes everything.

```bash
cd recorder && go build -o backfill ./cmd/backfill   # GOOS=linux GOARCH=amd64 for atlas
CLICKHOUSE_PASSWORD=... ./backfill -machine <name> -client-ip <tailnet ip> \
  -claude-dir ~/.claude/projects -codex-dir ~/.codex/sessions -t3-dir ~/.t3/userdata \
  [-until <when live recording started for this machine>] [-dry-run]
```

Re-running inserts again; clear a machine first:
`DELETE FROM prometheus.requests WHERE machine = '<name>' AND source LIKE 'backfill%'`.
For machines whose traffic already goes through the hub (atlas), pass
`-until` with the time the recorder went live there, so calls aren't counted
twice.

Token conventions follow the provider: Claude's `input_tokens` is uncached
input (prompt = input + cache_read + cache_creation); Codex's `input_tokens`
already includes `cache_read_tokens` (prompt = input). Live rows are the same.

```sql
-- prompt tokens and cache hit per T3 thread
SELECT t.machine, t.title, count() calls,
       sum(if(r.provider = 'codex', r.input_tokens, r.input_tokens + r.cache_read_tokens + r.cache_creation_tokens)) prompt_tokens,
       round(sum(r.cache_read_tokens) / prompt_tokens, 2) cache_hit, sum(r.output_tokens) output_tokens
FROM prometheus.requests r
JOIN (SELECT * FROM prometheus.t3_threads FINAL WHERE native_session_id != '') t
  ON if(r.parent_session_id != '', r.parent_session_id, r.session_id) = t.native_session_id
GROUP BY 1, 2 ORDER BY prompt_tokens DESC LIMIT 20;
```

## Sign in accounts

```bash
# Codex — device code, open the printed URL anywhere
docker exec -it prometheus-cli-proxy-api-1 ./CLIProxyAPI -codex-device-login

# Claude — open the printed URL in your browser; the final redirect to
# http://localhost:54545/callback?... fails there. Copy that URL and replay it
# inside the container's network namespace:
docker exec -it prometheus-cli-proxy-api-1 ./CLIProxyAPI -claude-login -no-browser
docker exec prometheus-cli-proxy-api-1 wget -qO- 'http://localhost:54545/callback?code=...&state=...'
```

Repeat per account. Never copy auth files between machines.

## Clients

Claude Code `~/.claude/settings.json`:

```json
{ "env": {
  "ANTHROPIC_BASE_URL": "https://prometheus.takaya-buri.ts.net",
  "ANTHROPIC_AUTH_TOKEN": "<access key>"
} }
```

Codex `~/.codex/config.toml`:

```toml
model_provider = "prometheus"

[model_providers.prometheus]
name = "prometheus"
base_url = "https://prometheus.takaya-buri.ts.net/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = true
experimental_bearer_token = "<access key>"
```

Bench an account: `"disabled": true` in its JSON under `/opt/prometheus/auths`
(no restart). Codex `token_invalidated` (401) → rerun the device login.

## Rules

- Claude subscriptions only from Claude Code. No other apps, no serving other
  people's traffic.
- Anything with Docker access in forge-linux (the CI runners) can read
  `/opt/prometheus/auths`. Keep untrusted code (fork PRs on public repos) off
  the forge runners.
