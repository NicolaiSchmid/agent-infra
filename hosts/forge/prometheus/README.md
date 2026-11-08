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

## Install

```bash
ssh nschmid10049@forge
limactl shell forge-linux
sudo apt-get install -y docker-compose-plugin   # once
sudo install -d -o "$USER" /opt/prometheus /opt/prometheus/{auths,ts-state,logs}
# copy config.example.yaml → /opt/prometheus/config.yaml, fill both keys (chmod 600)
# put TS_AUTHKEY in ~/prometheus/.env (chmod 600)
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

After changing the Dockerfile: `docker compose build && docker compose up -d cli-proxy-api`.

## Sign in accounts

The image also includes [Codex Auto Reset](https://github.com/JefferyZhang2019/cpa-plugin-codex-auto-reset)
v0.1.13, pinned by checksum. Select Codex accounts in its plugin settings;
the example configuration starts with no accounts selected. It checks every
five minutes and schedules redemption fifteen minutes before the earliest credit
expires. State lives under the persistent auth volume. After first setup,
edit settings in the plugin panel/API: its saved settings override YAML.
See [the source review and limitations](codex-auto-reset-review.md).

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

## Custom quota dashboard

Open **https://prometheus.takaya-buri.ts.net/dashboard/** on the tailnet.
No browser key login: the dashboard sidecar holds the management key and exposes
only sanitized quota snapshots and a rate-limited refresh action. The existing
management panel still requires its key. Inference routes keep their access key.
Anyone allowed to reach this node on port 443 can view the dashboard (including
account emails via "Show emails"); use tailnet ACLs to restrict that audience.

The standard-library Python sidecar lives in `dashboard/`, listens only on
loopback in Tailscale's network namespace, and runs as UID/GID 65532 with a
read-only root filesystem. No auth-file volume or generic management proxy is
exposed to it. It calls the existing management API to fetch quota through the
hub's residential egress; account OAuth tokens stay inside CLIProxyAPI.

Provision once **inside forge-linux**, without printing either key:

```bash
sudo install -d -o 65532 -g 65532 -m 700 /opt/prometheus/dashboard
# Write the existing plaintext management key (not config.yaml's bcrypt hash)
# into /opt/prometheus/dashboard-management-key; owner 65532:65532, mode 0400.
# The running installation derives this file from /opt/prometheus/keys.env.
cd ~/prometheus
docker compose -f docker-compose.yml -f dashboard/compose.yaml up -d --no-deps --build dashboard
```

Merge the `/dashboard` handler from `serve.json` into the live file, preserving
other routes such as the ClickHouse port. Apply without restarting the shared
Tailscale namespace or proxy:

```bash
docker exec prometheus-tailscale-1 tailscale serve --bg --yes --https=443 \
  --set-path=/dashboard http://127.0.0.1:8318/dashboard
```

The saved Serve configuration must also contain that handler for container
recreation. Keep `dashboard/compose.yaml` in subsequent Compose commands when
managing this sidecar. `restart: unless-stopped` brings it back with Docker.

Quota snapshots persist in `/opt/prometheus/dashboard/quota.db` (SQLite WAL),
every five minutes, retained for 90 days; the UI shows up to 14 days. Historical
request logs cannot reconstruct historical remaining quota. Failed polls retain
the last successful account snapshot with its timestamp and error, exclude stale
accounts from the current pool, and never write invented history points.

Each account contributes 100 percentage points to the pool; different plan
capacities are **not** inferred. Weekly and five-hour windows stay separate.
Missing provider windows display as unavailable. Forecasts need at least 30
minutes of contiguous observations for every included account, use the last
three hours of non-reset quota changes, and project up to seven days at constant burn
with known resets (12 hours for the five-hour window). The future-usage selector
scales that estimated burn; drain-rate charts use observed quota changes. These are estimates, not provider guarantees.

Check `GET /dashboard/health` for process health and `/dashboard/api/state` for
collector errors/freshness. Targeted tests:
`python3 -m unittest discover -s hosts/forge/prometheus/dashboard -p 'test_*.py'`.
CI runs these independently from the full Nix checks.

Rollback: remove only the `/dashboard` handler from the saved Serve config and
run `tailscale serve --https=443 --set-path=/dashboard off` inside the Tailscale
container, then `docker compose -f docker-compose.yml -f dashboard/compose.yaml
stop dashboard`. Keep the data directory for a later restart.

The dashboard layout follows Theo's quota screenshot: provider tabs, remaining/
drain modes, 1h/3h/6h burn windows, future-usage scenarios, and expandable account
rows. Configuration navigation opens the existing key-protected management UI.
The body is fixed to the viewport; only the content pane scrolls, with
`overscroll-behavior: none` on the document and scroll containers to prevent
boundary bounce/scroll chaining.
