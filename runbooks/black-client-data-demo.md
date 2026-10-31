# Client-data stack demo on black (Convex, Garage, E2B, Traefik)

> **Demo. It must not hold real client data.** Tax-firm client data falls
> under § 203 StGB and may only touch infrastructure under our control, on a
> host that does nothing else. black runs the atlas agent VM. Before the first
> tax-firm contract this stack moves to a dedicated Hetzner server (see
> [Move to a dedicated server](#move-to-a-dedicated-server)).

Set up on 2026-10-30 to move June (NicolaiSchmid/nicoolai: Next.js + Convex
Cloud + Vercel Sandbox) onto infrastructure under our control. Everything is
declared in `hosts/black/client-data.nix` and the files it imports; all state
lives in `/var/lib/client-data`.

## What runs where

All on black (bare metal, real KVM), as Docker Compose projects run by
systemd units, inside `client-data.slice` (CPU/IO weight 20 next to atlas's
qemu, quota 3 CPUs, MemoryMax 3G):

| Unit / project | What | Reached at |
|---|---|---|
| `traefik` (`hosts/black/traefik/`) | TLS on 80/443, Host-rule routing, ACME | public 80/443; tailnet-only `:443` (Traefik dashboard); unpublished `:6792` for the Convex dashboard's node |
| `convex-<name>` (`hosts/black/convex/compose.yaml`, one project per deployment) | Convex backend, SQLite, files in Garage | `https://<name>.convex.modusservice.com` (API, WebSocket), `https://<name>-site.convex.modusservice.com` (HTTP actions); loopback `127.0.0.1:<cloudPort>/<sitePort>` |
| `convex-dashboard` (`convex/dashboard.yaml`, `convex/portal.mjs`) | one dashboard for all deployments, behind a passkey portal, on its own tailnet node `convex` | `https://convex.takaya-buri.ts.net` (tailnet only) |
| `garage` (`hosts/black/garage/`) | single-node S3 (Garage v2.5.0) | docker network `garage` (`http://garage:3900`), `127.0.0.1:3900` (S3), `127.0.0.1:3903` (admin) |
| `convex-provision` | Garage layout, per-deployment buckets, keys and secrets | oneshot |
| `convex-<name>-backup.timer` | daily snapshot export into Garage | 03:30 + up to 30 min |
| `e2b` (`hosts/black/e2b.nix`, E2B Embed compose) | Firecracker sandboxes | tailnet: `http://black.takaya-buri.ts.net:3000` (api), `http://100.125.234.34:3002` (client-proxy); Convex containers: `http://host.docker.internal:3000`, `http://172.17.0.1:3002` |

Deployments (in `hosts/black/convex.nix`, `deployments`):

| Deployment | Cloud origin | Site origin | Loopback ports | Memory / CPUs |
|---|---|---|---|---|
| `june-dev` | `https://june-dev.convex.modusservice.com` | `https://june-dev-site.convex.modusservice.com` | 13210 / 13211 | 768m / 1 |
| `june-prod` | `https://june-prod.convex.modusservice.com` | `https://june-prod-site.convex.modusservice.com` | 13220 / 13221 | 1g / 1.5 |
| `modus-gateway-dev` | `https://modus-gateway-dev.convex.modusservice.com` | `https://modus-gateway-dev-site.convex.modusservice.com` | 13230 / 13231 | 512m / 0.5 |
| `modus-gateway-prod` | `https://modus-gateway-prod.convex.modusservice.com` | `https://modus-gateway-prod-site.convex.modusservice.com` | 13240 / 13241 | 768m / 1 |

`CONVEX_CLOUD_ORIGIN` and `CONVEX_SITE_ORIGIN` are these hostnames.

Not reachable from the internet: the dashboards, Garage, E2B (its api,
client-proxy and the orchestrator's unauthenticated control API on 5008).
Admin routes on Traefik answer 403 outside `100.64.0.0/10` and
`fd7a:115c:a1e0::/48`; black's firewall refuses the E2B ports other than
3000/3002 from the tailnet.

## DNS

Each public hostname has its own A and AAAA record in `NicolaiSchmid/dns`
(`zones/general/modusservice.com.yaml`, DNS-only, no wildcard), since the
DNS change for the convex hosts (NicolaiSchmid/dns#104) on 2026-10-31:

| Name | A | AAAA |
|---|---|---|
| `june-dev.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `june-dev-site.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `june-prod.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `june-prod-site.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `modus-gateway-dev.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `modus-gateway-dev-site.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `modus-gateway-prod.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |
| `modus-gateway-prod-site.convex.modusservice.com` | `65.109.71.108` | `2a01:4f9:3051:4d41::2` |

Traefik uses the Let's Encrypt production CA (`ACME_CA_SERVER` in
`hosts/black/traefik/black.env`). Create a new hostname's records before
its router goes live, or HTTP-01 fails and Let's Encrypt's failed-validation
limit kicks in.

## Secrets

All root-owned, mode 0600, under `/var/lib/client-data/secrets/` on black,
generated on first start, never in Git or SOPS (they belong to this data
directory and move with it). Never print them.

| File | Contents | Written by |
|---|---|---|
| `convex-<name>.env` | `INSTANCE_SECRET`, Garage key (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) | `convex-provision` |
| `convex-<name>-admin-key` | admin key for the CLI and dashboard | `convex-<name>` (first start) |

The portal keeps its own state in `/var/lib/client-data/convex/portal/`:
the session key (`session-key.json`), the enrolled passkeys' public keys
(`passkeys.json`) and a pending enrollment (`enroll.json`). Deleting
`session-key.json` and restarting `convex-dashboard` signs everyone out;
deleting an entry from `passkeys.json` revokes that passkey.
| `garage.env` | `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`, `GARAGE_METRICS_TOKEN` | `garage` |
| `convex-tailscale.env` | `TS_AUTHKEY` for the `convex` node's first login; delete after | by hand (Dashboard) |
| `e2b.env` | `TEAM_API_KEY` (SDK key), `ADMIN_TOKEN`, `SANDBOX_ACCESS_TOKEN_HASH_SEED` | `e2b-secrets` |

Each deployment's Garage key can read and write only its own buckets
(`<name>-files`, `-modules`, `-search`, `-exports`, `-snapshot-imports`,
`-backups`).

## Deploy a Convex app

```bash
export CONVEX_SELF_HOSTED_URL=https://june-dev.convex.modusservice.com
export CONVEX_SELF_HOSTED_ADMIN_KEY="$(ssh root@black cat /var/lib/client-data/secrets/convex-june-dev-admin-key)"
npx convex deploy
```

Until DNS exists, go through an SSH tunnel instead:
`ssh -N -L 23210:127.0.0.1:13210 root@black` and
`CONVEX_SELF_HOSTED_URL=http://127.0.0.1:23210`. The app's client uses
`https://<name>.convex.modusservice.com`; HTTP actions are on the `-site`
host.

## Dashboard

Open `https://convex.takaya-buri.ts.net` from the tailnet, sign in with
a passkey, pick a deployment. The portal (`convex/portal.mjs`) frames the
dashboard and hands it the deployment URL and admin key, so nobody copies
keys. The tailnet is not only the admin (atlas and its agents are on it),
hence the passkey: without a session Traefik's forwardAuth lets no
dashboard request through, and the admin keys never leave black except into
a signed-in browser tab. Sessions last 12 hours.

The address is its own tailnet node (a Tailscale container in
`convex/dashboard.yaml`, state in `/var/lib/client-data/convex/tailscale/`),
so it stays the same when the stack moves to another machine; the public
deployment hosts move with DNS. Its first login needs an auth key
(a browser login times out after 60 s in the container): create a
one-off, pre-approved key in the Tailscale admin console (Settings, Keys),
then

```bash
ssh root@black 'umask 077; read -rs k; printf "TS_AUTHKEY=%s\n" "$k" > /var/lib/client-data/secrets/convex-tailscale.env; systemctl restart convex-dashboard'
```

paste the key (no echo) and press Enter. Once `convex` is online, disable
its key expiry in the admin console and delete the key file; the identity
stays in `/var/lib/client-data/convex/tailscale/`. Passkeys belong to the
hostname: a new hostname means enrolling again.

Add a passkey (the first one, or another device) with a one-time link:

```bash
ssh root@black convex-portal-enroll
```

and open the printed link within 15 minutes on the device that should hold
the passkey. The link is good for one passkey.

### Calling E2B from Convex

Set on the deployment (`npx convex env set ...`):

```text
E2B_API_KEY=<TEAM_API_KEY from secrets/e2b.env>
E2B_API_URL=http://host.docker.internal:3000
E2B_SANDBOX_URL=http://172.17.0.1:3002
```

and pass them to `Sandbox.create(template, { apiKey, apiUrl, sandboxUrl })`
in a `"use node"` action. The sandbox URL must be an IP: client-proxy routes
by Host header (`<port>-<sandboxId>.<domain>`) and only falls back to the
SDK's routing headers for IP or `localhost` hosts, so
`host.docker.internal:3002` gets `400 Invalid host`. From the tailnet use
`E2B_API_URL=http://black.takaya-buri.ts.net:3000` and
`E2B_SANDBOX_URL=http://100.125.234.34:3002`.

### Egress control (E2B compared with Vercel Sandbox)

- **E2B Embed:** per sandbox at create time, `allowInternetAccess: false`
  (same as `denyOut: ["0.0.0.0/0"]`), or `network: { allowOut, denyOut }`
  where `allowOut` takes CIDRs, IPs or domains (`*.example.com`) and wins
  over `denyOut`, which takes CIDRs/IPs only. Changeable on a running sandbox
  (`SandboxNetworkUpdateConfig`). Domain rules are enforced by the
  orchestrator's TCP firewall (HTTP Host / TLS SNI inspection on ports
  80/443, CIDR only for other ports). `rules` can inject headers per domain;
  `egressProxy` routes through a proxy. Private ranges are denied by default
  (`ALLOW_SANDBOX_INTERNAL_CIDRS` opens some node-wide). Verified 2026-10-30:
  `allowInternetAccess: false` blocks `curl https://example.com`; the default
  reaches it (200).
- **Vercel Sandbox:** `networkPolicy` of `allow-all` (default), `deny-all`
  (including DNS), or user-defined: allowed domains (SNI, wildcards by whole
  label), allowed and denied CIDR ranges. Updatable at runtime without a
  restart. Rules on an allowed domain do credential brokering (`transform`
  headers, secrets never enter the sandbox, TLS terminated with a per-sandbox
  CA) or request proxying (`forwardURL` with an OIDC token), with matchers on
  path, method, query and headers. Postgres with TLS can be filtered by
  domain.

## Add a deployment

One entry in `deployments` in `hosts/black/convex.nix` (name, two unused
loopback ports, memory, CPUs), then switch. `convex-provision` creates its
buckets, key and secrets file; the unit starts the backend and writes its
admin key; Traefik picks up its two routers from the labels; the portal
lists it after `convex-dashboard` reloads in the same switch. Add its two
hostnames to the DNS repository first (section DNS).

## Custom domains

A customer domain in front of an origin is one more router in
`hosts/black/traefik/dynamic/custom-domains.yml` (an example is in the
file), pointing at the service the labels define (`<name>-cloud@docker` or
`<name>-site@docker`) with `certResolver: letsencrypt`, plus the customer's
A/AAAA (or CNAME) record to black. Note that Convex builds its own URLs
(file storage, HTTP action links) from `CONVEX_CLOUD_ORIGIN`/
`CONVEX_SITE_ORIGIN`, so a custom domain for a deployment's primary origin
means changing those too.

## Data stays local

- `DISABLE_BEACON=true`: the self-hosted beacon (a random id and the backend
  version, sent to Convex) is off. With `REDACT_LOGS_TO_CLIENT=true` these
  are the two items in upstream's "disabling logging features" guide
  (`self-hosted/advanced/disabling_logging.md`): the backend redacts function
  log details in responses to clients, as Convex Cloud does.
- `DISABLE_METRICS_ENDPOINT=true`: no Prometheus `/metrics`.
- `NEXT_PUBLIC_LOAD_MONACO_INTERNALLY=true`: the dashboard loads its editor
  from the image instead of a CDN.
- E2B Embed exports no telemetry (its OTEL endpoint is empty); its logs stay
  in its own ClickHouse.

## Restricting admin endpoints on 3210 (assessed, not enabled)

Traefik could put a higher-priority router on each cloud host with
`PathPrefix` matches and the `tailnet-only` middleware. The paths:

- CLI deploy and admin: `/api/deploy2/*` (`start_push`, `evaluate_push`,
  `evaluate_schema`, `wait_for_schema`, `finish_push`,
  `report_push_completed`), `/api/get_config_hashes`,
  `/api/update_environment_variables`, `/api/run_test_function`,
  `/api/export/request/zip`, `/api/export/zip/<ts>`, `/api/import/*`
  (`start_upload`, `upload_part`, `finish_upload`), `/api/perform_import`,
  `/api/stream_function_logs`, `/api/shapes2`, `/api/current_deployment`,
  `/api/v1/*`.
- Dashboard, in addition: `/api/check_admin_key`, `/api/app_metrics/*`,
  `/api/cancel_job`, `/api/cancel_all_jobs`, `/api/delete_tables`,
  `/api/delete_component`, `/api/delete_scheduled_functions_table`,
  `/api/function`, `/api/query_ts`, `/api/query_at_ts`.
- Shared with app clients (cannot be restricted): `/api/sync` (WebSocket),
  `/api/query`, `/api/mutation`, `/api/action`, `/api/storage/*`.

Trade-off: every one of those already requires the admin key, and the
dashboard and CLI also read data through the shared endpoints with that key
(system queries on `/api/query` and `/api/sync`), so the restriction narrows
what a leaked admin key can do from the internet without making the key
harmless. It would also mean Vercel builds can no longer run
`npx convex deploy`: deploys would have to run from the tailnet (a GitHub
Actions job with a Tailscale auth key, or by hand).

## Backups and restore

`convex-<name>-backup.timer` runs daily: it requests a snapshot export
including file storage (`POST /api/export/request/zip?includeStorage=true`,
what `npx convex export --include-file-storage` does), waits for it, downloads
the zip and uploads it to `<name>-backups/daily/<UTC time>-<ts>.zip` in
Garage, keeping the newest 14. The backend also keeps its own copy of each
export in `<name>-exports` for 14 days.

```bash
systemctl start convex-june-dev-backup      # run now
journalctl -u convex-june-dev-backup -n 20
```

Restore (tested on 2026-10-30 against `june-dev`: the notes table
overwritten, then restored from the Garage backup, file storage included):

```bash
# on black: fetch the newest backup with the deployment's own key
ssh root@black '
  set -a; . /var/lib/client-data/secrets/convex-june-dev.env; set +a
  rc=$(ls -d /nix/store/*-rclone-*/bin/rclone | head -1)
  export RCLONE_CONFIG_G_TYPE=s3 RCLONE_CONFIG_G_PROVIDER=Other \
    RCLONE_CONFIG_G_ENDPOINT=http://127.0.0.1:3900 RCLONE_CONFIG_G_REGION=garage \
    RCLONE_CONFIG_G_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID RCLONE_CONFIG_G_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
  $rc cat g:june-dev-backups/daily/$($rc lsf g:june-dev-backups/daily | sort | tail -1)' > restore.zip
# from a project directory, with CONVEX_SELF_HOSTED_URL/ADMIN_KEY set:
npx convex import --replace-all -y restore.zip
```

Environment variables are not in the export; keep them with
`npx convex env list` if they matter. A Garage outage or loss takes the
backups with it: they protect against bad deploys and deleted data, not
against losing black. Off-host copies are part of the move.

## Health and operations

```bash
ssh root@black 'systemctl is-active traefik garage convex-provision convex-june-dev convex-june-prod convex-dashboard e2b'
ssh root@black 'docker stats --no-stream; cat /sys/fs/cgroup/client.slice/client-data.slice/memory.current'
ssh root@black 'docker exec garage /garage status; docker exec garage /garage bucket list'
```

Upgrading Convex: bump the image tag and digest in
`convex/compose.yaml` and `convex/dashboard.yaml` (export first; see
upstream `self-hosted/advanced/upgrading.md`). E2B: bump `rev` and both
hashes in `e2b.nix` together.

### Things learned on 2026-10-30

- black's memory is fragmented: `vm.nr_hugepages` set at runtime reached
  ~800 of 1024 pages even after compaction, so `HUGEPAGES=768`. With 512,
  resuming a paused 512 MiB sandbox failed (`mmap memfd: cannot allocate
  memory`): the restore needs a memfd besides the ~120 pages the orchestrator
  keeps reserved.
- tmpfiles `d` rules re-own existing directories on every switch; the
  database volume directories are therefore created in `ExecStartPre`, not
  by tmpfiles.
- A switch on black waits up to 90 s for a `dbus-broker` reload that times
  out; harmless, but the switch takes that long.
- E2B's ClickHouse runs near its 768m cap at idle. If it gets OOM-killed,
  raise its `mem_limit` in `e2b/compose.black.yaml` (and the slice).

## Move to a dedicated server

The stack is host-neutral apart from these: `stateDir` and `baseDomain`
(`client-data.nix`, `convex.nix`), the two `black.env` files,
the hugepage count, and the slice budget. To move:

1. Install NixOS on the new Hetzner server (bare metal: KVM without nesting).
   Add a host under `hosts/<name>/` that imports `client-data.nix` and the
   files next to it (move them to a shared `modules/client-data/`), with its
   own `stateDir` and a slice sized for a dedicated machine
   (drop the 3 CPU / 3G ceiling, raise `HUGEPAGES` to 2048 or more).
2. Stop the stack on black (`systemctl stop convex-june-dev convex-june-prod
   convex-dashboard e2b garage traefik`) and copy
   `/var/lib/client-data` with `rsync -aHAX --numeric-ids`. It holds SQLite,
   Garage, E2B's databases and templates, certificates, secrets, the
   portal's passkeys and the `convex` tailnet node's identity, so the
   dashboard keeps its address and passkeys.
3. Switch the new host, check it, then point the DNS records at its IP.
   Remove `client-data.nix` from black.

What changes there:

- **TLS:** Traefik stays; Let's Encrypt in production, HTTP-01 or DNS-01
  (Cloudflare, as in nunc-immo/compose-services) for wildcards.
- **Storage:** Garage can stay on the host. For storage off the host, point
  the backends' S3 settings at Hetzner Object Storage instead:
  `S3_ENDPOINT_URL=https://<location>.your-objectstorage.com`,
  `AWS_REGION=<location>`, `AWS_S3_FORCE_PATH_STYLE` as Hetzner documents,
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in the secrets file, and the
  five `S3_STORAGE_*_BUCKET` names. Moving between storage backends needs
  `npx convex export` and `npx convex import --replace-all` (upstream
  `s3_storage.md`). Backups should go off the host in any case.
- **Sandboxes:** E2B on bare-metal KVM; size `HUGEPAGES` and `NBDS_MAX` for
  the concurrent sandboxes. If Firecracker were ever unavailable, the known
  fallback is OpenSandbox with gVisor (not built).
- **Isolation:** the server runs this stack only; no agent VM next to it.
