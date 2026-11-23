# June executor database on black (sqld)

June's executor database is the Executor SDK's integration registry:
connections and their labels, tool catalogues, OAuth clients and sessions.
Secrets are not in it; they live in Convex (`integrationSecrets`). June's
Convex opens it on every chat turn. Until the cutover it is a Turso Cloud
database (AWS eu-west-1). This stack replaces Turso for that role. Decided by
Nicolai Schmid on 2026-11-23.

Declared in `hosts/black/executor-db.nix`, `hosts/black/executor-db/`
(template and instances) and the network join in `hosts/black/convex.nix`.
State lives under `/var/lib/client-data`, so it moves with the rest of the
stack (`runbooks/black-client-data-demo.md`, "Move to a dedicated server").

The June side holds the data move from Turso, the Convex env switch and its
verification: `docs/infrastructure/executor-database.md` in
NicolaiSchmid/june.

## What runs

| Instance | Used by | URL inside Docker | Loopback | Memory |
|---|---|---|---|---|
| `june-prod` | `convex-june-prod` | `http://executor-db-june-prod:8080` | `127.0.0.1:13280` | 256m |
| `june-dev` | `convex-june-dev` | `http://executor-db-june-dev:8080` | `127.0.0.1:13281` | 128m |

Both instances run in `executordb.slice` (448M hard, no swap), outside
`client-data.slice`. A demo deployment's memory spike cannot take the
registry with it.

Per instance:

- `executor-db-<name>.service` starts the compose project. On first start it
  creates the internal network `executor-db-<name>` and the key
  `secrets/executor-db-<name>-jwt.key`.
- `executor-db-<name>-health.timer` runs every 5 minutes: `/health`, then an
  authenticated read.
- `executor-db-<name>-backup.timer` runs daily at 03:15 (plus up to
  15 minutes). It writes a gzip SQL dump to
  `garage:executor-db-<name>-backups/daily/`, kept 30 days, the newest
  always kept.
- A failed health or backup run starts `executor-db-failed@<unit>`. That
  unit writes a fixed journal line and, once Pushover is enabled, sends the
  fixed "Executor database failed" push, at most once per unit and hour.

Network boundary:

- The server is on two networks. One is the internal `executor-db-<name>`,
  shared only with its one Convex backend. The other is its compose default
  network, which exists only to publish the loopback port.
- There is no Traefik label and no public port.
- Every request, `/dump` included, needs a JWT signed with the instance's
  key. Only `/health` answers without one.

## Tokens

```bash
ssh root@black
executor-db-token june-prod ro 600   # read-only, 10 minutes, for a check
executor-db-token june-prod rw       # read-write, no expiry (Convex's token)
```

Tokens never go into Git, PR text or chat. `executor-db-convex-env <name>`
does the cutover step: it writes `EXECUTOR_DATABASE_URL` and a fresh
read-write `EXECUTOR_DATABASE_AUTH_TOKEN` into that instance's Convex
deployment through the admin API on loopback and prints only the names.
Changing a Convex env var takes effect on the next function call; there is no
deploy.

To query from Atlas, tunnel the loopback port:
`ssh -N -L 23280:127.0.0.1:13280 root@black`. Then use
`http://127.0.0.1:23280` with a token from `executor-db-token`. June's
`pnpm executor:db:init` accepts this `http://` loopback URL.

## Rotate the key (revoke every token)

A token without `exp` stays valid until the key changes. To revoke all tokens
of an instance:

```bash
ssh root@black
mv /var/lib/client-data/secrets/executor-db-june-prod-jwt.key{,.old}
systemctl restart executor-db-june-prod   # new key, new public half
executor-db-convex-env june-prod          # Convex gets a token for the new key
rm /var/lib/client-data/secrets/executor-db-june-prod-jwt.key.old
```

Convex calls between the restart and the env update fail with 401. That is a
few seconds; do it outside working hours for `june-prod`.

## Restore from a backup

A dump is plain SQL (`PRAGMA`, `BEGIN`, `CREATE … IF NOT EXISTS`, `INSERT`,
`COMMIT`), the same format as the Turso export in the June runbook. Restore
into an empty server:

```bash
ssh root@black
systemctl stop executor-db-june-prod
mv /var/lib/client-data/executor-db/june-prod{,.broken-$(date -u +%Y%m%dT%H%M%SZ)}
systemctl start executor-db-june-prod     # empty database
nix shell nixpkgs#rclone                  # rclone is not on black's PATH
set -a; . /var/lib/client-data/secrets/executor-db-june-prod-backup.env; set +a
export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
  RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 RCLONE_CONFIG_GARAGE_REGION=garage \
  RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
umask 077; mkdir -p /root/executor-db-restore && cd /root/executor-db-restore
latest=$(rclone lsf garage:executor-db-june-prod-backups/daily | sort | tail -n 1)
rclone copyto "garage:executor-db-june-prod-backups/daily/$latest" dump.sql.gz && gunzip dump.sql.gz
jq -Rs '{requests: [{type: "sequence", sql: .}]}' dump.sql > request.json
curl -fsS -H "Authorization: Bearer $(executor-db-token june-prod rw 600)" \
  -H 'content-type: application/json' --data-binary @request.json \
  http://127.0.0.1:13280/v2/pipeline | jq -c '.results[0].type'   # "ok"
cd / && rm -r /root/executor-db-restore
```

The key is unchanged, so Convex's token keeps working. Then check the row
counts against the dump: count the `INSERT INTO <table>` lines per table.

## Moving hosts

Copy `/var/lib/client-data/executor-db/` and the
`executor-db-*` files in `secrets/` with the rest of the data directory.
Ports, memory and the Convex pairing are in `executor-db/instances.nix`;
nothing in the template names black.

## Known gaps

- **No off-host copy yet.** The daily dumps go to Garage on the same disks.
  The Storage Box job (`storage-box.nix`) only takes Convex export zips.
  Until it takes these dumps too, losing black's disks loses the registry
  since the last off-host Convex backup. Users would have to reconnect
  integrations. Their secrets survive in Convex.
- Pushover delivery is off until an application token exists (same as the
  hosted runner and the backups).
- Only June's executor database moved. June's data workspaces still use
  Turso; they move separately.
