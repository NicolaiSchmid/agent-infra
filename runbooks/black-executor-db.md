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
  always kept. The same dump then goes off-host into the Storage Box Borg
  repository that holds the Convex backups, as archive series
  `executor-db-<name>` (see [Off-host copy](#off-host-copy-storage-box)).
- A failed health or backup run starts `executor-db-failed@<unit>`. That
  unit writes a fixed journal line and reports `executor-db firing` with the
  unit name to June's prod deployment (`scripts/june-alert.py`, every
  instance, june-dev's included), authenticated with
  `/root/hosted-runner/june-prod-runner.key`. June dedupes the repeats of a
  health timer that keeps failing every 5 minutes and alerts its staff. Once
  June accepted "firing", the unit leaves a stamp in
  `/var/lib/executor-db-alerts/<unit>.firing`; the next successful run starts
  `executor-db-recovered@<unit>` (`OnSuccess=`), which reports `resolved`
  and removes the stamp. Without a stamp a success sends nothing.
- June's side must be deployed first: until `hostedRuns/alerts:report`
  exists the report fails, `executor-db-failed@` ends failed and only the
  journal line remains. Test by hand (sends one real alert, then resolves
  it on the next health run within 5 minutes):
  `systemctl start executor-db-failed@executor-db-june-prod-health.service`.

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

## Off-host copy (Storage Box)

After the Garage upload, the backup unit hands the dump to
`product-backup-executor-db <name> <dump>` (`hosts/black/storage-box.nix`).
It uses the same repository, writer key, age recipient and lock as the
Convex backups ([storage-box-product-recovery.md](storage-box-product-recovery.md)).
`scripts/storage-box/backup.py executor-db`:

- checks the dump (whole gzip, ends in `COMMIT;`) and counts the `INSERT`
  lines per table;
- seals `dump.sql.gz`, `recovery.tar` (only
  `secrets/executor-db-<name>-jwt.key`, so the token in Convex's backed-up
  environment keeps working after a host restore) and `manifest.json` into
  `payload.tar.age`, encrypted to the operator's public recipient. Black
  cannot decrypt it;
- writes archive `executor-db-<name>-<ns>`, then the receipt
  `/var/lib/product-backup/executor-db-<name>.json`. The receipt holds the
  archive name, SHA256 and sizes of the dump, the `inserts` per table and
  Borg's statistics. No table content.

A failed off-host step still lets the Garage retention run, then fails the
backup unit, which reports `executor-db firing` as above. The hourly
`product-backup-health` check also expects both receipts and reports
`product-backup` when one is missing or older than 36 hours. Retention on
Forge (30 days, newest always kept) treats both series as current
(`hosts/forge/product-backup-retention.nix`).

Check the newest receipt and the remote archive from black (the writer key
may list and read, never delete):

```bash
ssh root@black
jq '{archive, sha256, dump_bytes, inserts, completed_at: (.completed_at | todate)}' \
  /var/lib/product-backup/executor-db-june-prod.json
# The runner's environment, without running the backup: BORG_REPO, BORG_RSH, passphrase command.
eval "$(grep -E '^\s*export BORG_' "$(command -v product-backup-executor-db)")"
nix shell nixpkgs#borgbackup -c borg list --glob-archives 'executor-db-june-prod-*' --last 3 \
  --format '{archive} {time}{NL}'
nix shell nixpkgs#borgbackup -c borg list --format '{path} {size} {mtime}{NL}' \
  "::$(jq -r .archive /var/lib/product-backup/executor-db-june-prod.json)"
```

To restore from the Storage Box (black's disks lost): on the recovery
machine that holds the age identity, `borg extract` the archive, decrypt
`payload.tar.age` and unpack it into a private directory. Check
`sha256sum dump.sql.gz` against `manifest.json`, put
`recovery.tar`'s key back at `secrets/executor-db-<name>-jwt.key`, and
replay `dump.sql.gz` into the empty server as below. To prove that the
archived dump restores without the identity, run the drill on the Garage
dump whose SHA256 equals the receipt's.

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
To test a backup without replacing the live database, run the drill below.

## Restore drill (live server untouched)

Proves that the newest backup restores, without touching the live
instance: the dump goes into a throwaway sqld with its own name
(`executor-db-drill`), loopback port (`13289`), Docker volume and Ed25519
key, so a drill token never works against a live server. It runs outside
`executordb.slice`, whose 448M are sized for the two live instances. Run it
after a change to the backup or restore path, and at least once a quarter.

```bash
ssh root@black
name=executor-db-drill port=13289 dir=/root/executor-db-drill
image=$(grep -o 'ghcr.io/tursodatabase/libsql-server:[^ ]*' \
  "$(systemctl cat executor-db-june-prod | grep -o '/nix/store/[^ ]*compose.yaml' | head -n 1)")
umask 077; mkdir -p "$dir" && cd "$dir"
PATH=$(nix build --no-link --print-out-paths 'nixpkgs#rclone^out')/bin:$(nix build --no-link --print-out-paths 'nixpkgs#openssl^bin')/bin:$PATH
openssl genpkey -algorithm ed25519 -out jwt.key
openssl pkey -in jwt.key -pubout -out jwt.pub && chmod 0644 jwt.pub && chmod 0755 "$dir"
drill_token() {  # rw, 15 minutes, signed with the drill key
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  local h p; h=$(printf '{"alg":"EdDSA","typ":"JWT"}' | b64url)
  p=$(printf '{"a":"rw","exp":%s}' $(( $(date +%s) + 900 )) | b64url)
  printf '%s.%s' "$h" "$p" > msg
  printf '%s.%s.%s' "$h" "$p" "$(openssl pkeyutl -sign -rawin -inkey jwt.key -in msg | b64url)"
}
set -a; . /var/lib/client-data/secrets/executor-db-june-prod-backup.env; set +a
export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
  RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 RCLONE_CONFIG_GARAGE_REGION=garage \
  RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
latest=$(rclone lsf garage:executor-db-june-prod-backups/daily | sort | tail -n 1); echo "$latest"
rclone copyto "garage:executor-db-june-prod-backups/daily/$latest" dump.sql.gz && gunzip dump.sql.gz
docker run -d --name "$name" --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 128 \
  -e SQLD_DB_PATH=/var/lib/sqld/data -e SQLD_HTTP_LISTEN_ADDR=0.0.0.0:8080 \
  -e SQLD_AUTH_JWT_KEY_FILE=/run/sqld/jwt.pub -v "$name":/var/lib/sqld \
  -v "$dir/jwt.pub":/run/sqld/jwt.pub:ro -p 127.0.0.1:$port:8080 "$image"
until curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; do sleep 1; done
jq -Rs '{requests: [{type: "sequence", sql: .}]}' dump.sql > request.json
curl -fsS -H "Authorization: Bearer $(drill_token)" -H 'content-type: application/json' \
  --data-binary @request.json "http://127.0.0.1:$port/v2/pipeline" | jq -c '.results[0].type'   # "ok"
q() {  # q <port> <token> <sql>
  jq -n --arg s "$3" '{requests: [{type: "execute", stmt: {sql: $s}}]}' |
    curl -fsS -H "Authorization: Bearer $2" -H 'content-type: application/json' \
      --data-binary @- "http://127.0.0.1:$1/v2/pipeline" | jq -c '.results[0].response.result.rows // .results[0]'
}
live=$(executor-db-token june-prod ro 600)
tables=$(q 13280 "$live" "select name from sqlite_master where type = 'table' and name not like 'sqlite\_%' escape '\' and name not like '\_%' escape '\' order by name" | jq -r '.[][0].value')
counts=$(for t in $tables; do printf "select '%s', count(*) from \"%s\" union all " "$t" "$t"; done | sed 's/ union all $//')
for t in $tables; do printf '%s %s\n' "$t" "$(grep -c "^INSERT INTO \"\?$t\"\? " dump.sql || true)"; done > dump.txt
q "$port" "$(drill_token)" "$counts" | jq -r '.[] | "\(.[0].value) \(.[1].value)"' > drill.txt
q 13280 "$live" "$counts" | jq -r '.[] | "\(.[0].value) \(.[1].value)"' > live.txt
echo "table dump drill live"; join dump.txt drill.txt | join - live.txt
diff dump.txt drill.txt && echo "drill matches the dump"
q "$port" "$(drill_token)" "pragma integrity_check"   # [[{"type":"text","value":"ok"}]]
docker rm -f "$name" && docker volume rm "$name" && cd / && rm -r "$dir"
```

Pass: the restore answers `"ok"`, `drill` equals `dump` on every table, and
`integrity_check` is `ok`. `live` may differ from both: the backup is up to
a day old and tool catalogues are rewritten on refresh. A difference only in
`tool`, explained by `select count(*) from tool where created_at > <backup
time in epoch seconds>` on the live server, is expected.

Drill log:

| Date (UTC) | Backup | Result |
|---|---|---|
| 2026-11-24 | `2026-11-24T021606Z.sql.gz` | Restore ok, integrity ok, every table equal to the dump. Live had `tool` 937 against 935, from 724 rows rewritten after the backup on three connections; all other tables equal |

## Moving hosts

Copy `/var/lib/client-data/executor-db/` and the
`executor-db-*` files in `secrets/` with the rest of the data directory.
Ports, memory and the Convex pairing are in `executor-db/instances.nix`;
nothing in the template names black.

## Known gaps

- The off-host copy is daily. Losing black's disks loses up to a day of
  registry changes; users would reconnect what changed since. Their secrets
  survive in Convex.
- Decrypting an off-host archive needs the operator's age identity, which
  stays off black and Atlas. Drills on black restore the Garage dump with
  the receipt's SHA256, not the decrypted archive.
- Alerts depend on June prod answering: when it is down, the failure stays
  in the journal (`journalctl -u 'executor-db-failed@*'`) and no one is
  paged.
- Only June's executor database moved. June's data workspaces still use
  Turso; they move separately.
