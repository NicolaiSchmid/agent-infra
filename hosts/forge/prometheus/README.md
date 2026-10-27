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

After changing the Dockerfile: `docker compose build && docker compose up -d cli-proxy-api`.

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
