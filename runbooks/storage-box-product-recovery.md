# Encrypted off-host product recovery

Scope: the six Black Convex deployments, their storage-inclusive snapshot ZIPs,
instance/storage secrets and deployment source, and for June's deployments the
agent source repository and the hosted-workflow bundles the snapshot references
([black-agent-source.md](black-agent-source.md#backup-and-restore)). This is **not an Atlas VM backup**,
nor full E2B, ClickHouse, Garage, or host disaster recovery. Garage daily copies on
Black are not off-host recovery. No disk deletion or repartition is needed here.

## Activation work — 2026-11-11

The operator selected the existing Mac SSH public key for payload encryption and
supplied `u710483`. This is the parent account, not an assigned subaccount login.
The configured repository therefore uses the parent path. Black's dedicated writer
key must be forced to append-only Borg with `--restrict-to-repository
/home/product-backup/repo`; it must not retain general SSH or file-transfer access.
This replaces the previous subaccount activation dependency with an exact-repository
key restriction on the supplied account. The Mac retains separate maintenance
access. Temporary Atlas parent-account authorization was revoked after verification; the Mac retains maintenance access.

The four active deployments derive from `hosts/black/convex/deployments.nix`;
retired MODUS archives remain historical recovery material. On 2026-11-11 the
existing remote repository passed a fresh full `borg check --verify-data`.
The configuration now selects age payload encryption to the recorded Mac public
key; this does not change the encryption of historical bootstrap archives.

Recurring encrypted backups are active. All four fresh remote archives contain only
`payload.tar.age`, and a full remote Borg data check passed. The hourly freshness
check passed after those writes. See [activation evidence](storage-box-acceptance-2026-11-11.md).
Independent Mac decryption/key escrow remains unverified, and no external dead-man
monitor has been configured. The hourly host check reports stale archives to June
(see Operations and capacity); it cannot report Black itself being down.
Do not describe those remaining controls as complete.

## Provisioning status (2026-11-04)

Storage Box #692297 (`atlas-backup`, BX11, HEL1-BX570) is provisioned at
`u710483.your-storagebox.de`, with 1 TB reported capacity. Its ED25519 host key
matches the fingerprint in Hetzner's official HTTPS documentation:
`SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM`.
The encrypted repository is initialized at parent-account path
`product-backup/repo` using `repokey-blake2`. Initial completed exports for all six
products have been copied off-host, checked with `borg check --verify-data`, and
extracted/verified. All six passed isolated record/blob/config recovery drills; see
[dated acceptance evidence](storage-box-acceptance-2026-11-04.md). They are bootstrap copies; recurring off-host scheduling is
not yet activated. The dedicated subaccount exists according to the operator;
its username and final asymmetric recipient are still needed.

The bootstrap writer key is forced to append-only Borg under
`/home/product-backup`; its unrestricted OpenSSH and RFC4716 entries were removed.
Other pre-existing account keys were preserved. The final subaccount key must be
restricted to its exact repository, and the Atlas parent-account bootstrap key
must be removed after provisioning so retention authority remains on the Mac.
(Since 2026-11-19, scheduled retention runs on Forge with its own restricted key; see
[Retention](#retention-30-days).)
Black received only the writer key/passphrase, decrypted from SOPS with its host
identity, in root-only runtime files. No host rebuild or product restart occurred.

A disposable remote-repository test found: archive delete exit 0 (logical delete),
compact exit 0 (no data reclamation), full repository delete exit 2. Rolling a copy
back to the last good transaction recovered the deleted fixture with matching
SHA256. This proves the tested restriction, not immutable storage.

## Provision and activate

Official transport/version reference:
https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/
Use Borg 1.x with explicit `--remote-path=borg-1.4`, SSH port 23.

1. Provision a dedicated Storage Box subaccount with access restricted to this
   product repository directory. Record purchased capacity. Enable SSH, disable
   unneeded protocols. Obtain and verify its SSH host key independently.
2. On a trusted recovery workstation generate a dedicated SSH writer key and a
   strong Borg passphrase. Initialize the repository with
   `borg init --encryption=repokey-blake2 --remote-path=borg-1.4 REPOSITORY`.
   Export its key using `borg key export REPOSITORY recovery-key`.
   Store key export, passphrase, account recovery and retention credentials in
   an access-controlled recovery vault **outside Black**; test a second operator
   can obtain them. Repository key plus passphrase are both needed.
3. Install only the writer public key with a forced command
   `command="borg-1.4 serve --append-only --restrict-to-repository /home/REPO",restrict ssh-ed25519 …`
   adapting the actual supported absolute subaccount path after checking it.
   Follow Hetzner's authorized_keys setup on port 23. Verify the command is
   enforced; do not assume an SSH key is restricted merely because it is dedicated.
   Keep the separate retention key (see [Retention](#retention-30-days)) and
   the parent account off Black.
4. In a disposable repository with those same restrictions create two archives,
   attempt archive delete/prune/compact/repository delete with the writer, then
   inspect using retention authority. Record exit codes and recoverability from
   Borg transaction history. Append-only may permit logical deletion while
   retaining segments: it is **not immutable storage**. Reject activation if the
   writer can reclaim old data or escape its repository. Retention authority must
   never compact until unexpected deletions have been investigated.
5. Use private secret input on a trusted machine and SOPS-edit
   `secrets/product-backup.yaml` (never paste secrets into chat or command arguments).
   The encrypted writer key and passphrase are already present. Black's alerts
   need no secret here: they go to June with the june-prod hosted runner key
   (see Operations and capacity). A `product-backup/alert-config` entry left in
   the file is no longer read by Black. Black is an encrypted-file recipient.
   No plaintext secrets belong in Nix/store.
6. Set `services.productBackup.enable = true`, `repository` (SSH URL with
   `:23/./`) and `knownHosts` (verified `[host]:23` key). Evaluate and deploy
   through the normal host change procedure. Run each existing
   `convex-NAME-backup.service` manually, serially. A Borg warning/failure fails
   the service and does not advance the success receipt. Garage upload precedes off-host archiving; remote failure still permits local
   retention to finish and leaves the service failed without advancing off-host success.

No account password is needed for SSH-key operation. The parent account is used
only for bootstrap/retention; do not deliver its authority to Black.

### Optional asymmetric payload encryption

Set `services.productBackup.publicRecipient` to an age public key (`age1…`) or
supported SSH public key. The writer streams export ZIP + recovery tar + manifest
through age, then archives **only `payload.tar.age`** in the encrypted Borg
repository. Borg still uses `repokey-blake2`, but its writer key alone cannot
decrypt the age-protected contents. The age private identity belongs in Bitwarden
outside both Black and Atlas. Generate a dedicated age identity on the operator's
computer, save the private file in Bitwarden, and send only the public recipient.
An existing Mac SSH public key is also supported; its private key never needs to
be delivered to Black. Previously created bootstrap Borg-only archives do not
gain this extra layer retroactively.

Randomized age ciphertext intentionally prevents cross-snapshot deduplication.
Compression of an already-compressed ZIP offers little benefit. Measure the full
payload size and budget for every retained version. A recovery kit has also been
prepared encrypted to the existing Mac SSH public key; downloading and decrypting
it independently is still required before claiming off-host key escrow.

## Operations and capacity

Hourly health checks fail for each missing or >36h-old successful off-host archive,
including first activation. Every run reports both checks to June's prod deployment
through `scripts/june-alert.py` (`hostedRuns/alerts:report`, authenticated with
`/root/hosted-runner/june-prod-runner.key`): `product-backup` for a missing or stale
archive and `product-backup-bundles` for absent hosted bundles, each `firing` or
`resolved`. June dedupes the hourly repeats, writes the text and alerts its staff.
A failed report also fails the unit. June's side must be deployed first: until
`hostedRuns/alerts:report` exists every run fails on delivery. Test by hand with
`systemctl start product-backup-health` and read `journalctl -u product-backup-health -n 5`
(one `reported … to june-prod` line per check; a healthy run resolves both).
Systemd failure/journal must also be watched by the operator. An external dead-man monitor
is required to detect Black being down (a host cannot alert when powered off).
Do not mark activation complete until that monitor observes daily completion.

Root-only `/var/lib/product-backup/NAME.json` records ZIP compressed/uncompressed
bytes, SHA256 and Borg JSON statistics (original/compressed/deduplicated bytes).
Initial measurement: five available June production daily ZIPs total 430,115,231
bytes; a Borg ZIP-only measurement added 401,504,802 bytes. Three exports were
empty before migration; only the last two are populated, so this is not a steady
week of usage. The latest ZIP is 216,111,361 bytes and added 188,119,049 bytes after
the previous populated ZIP (about 13% reused). Exact duplicate ZIPs added zero
bytes in the measurement. June production is >99.9% of the six initial ZIP bytes.
Age wrapping would forgo that cross-version reuse; 28 versions at the current
ZIP size alone are about 5.64 GiB before recovery metadata and safety headroom.
Do not extrapolate the migration jump as an ordinary daily growth rate.

Continue to at least 7 daily exports per deployment and aggregate actual repository
size using retention credentials. Compressed ZIPs can deduplicate poorly. Size for
30 daily archives per deployment (the retention below) plus 30% headroom using
measured added bytes, not raw database size. Cache and manifests add local space; ZIPs are
hardlinked into a private temporary directory, not copied. Only one Borg job runs
at once; no local history is accumulated.

Retained append-only segments consume capacity until compaction. Alert on
provider quota independently.

## Retention (30 days)

MODUS's AVV Anlage 2 (TOMs, `docs/legal/toms.md` in `NicolaiSchmid/june`) and the
DSFA state that product data is backed up daily, encrypted, and kept 30 days.
Decision 2026-11-19 (Nicolai Schmid): **nothing older than 30 days**, automated, in
both copies: the Storage Box and Black's local Garage copy. A current deployment
always keeps its newest backup, so a stalled backup never deletes its last good copy.
That copy is reported as over-age. This replaces the earlier manual 14 daily /
8 weekly / 6 monthly suggestion (about six months). It also replaces a first proposal
of `--keep-daily 30`, which counts days with a backup: missed days would have kept
june-prod's data about 39 days.

Where it runs: **Forge**, as the root launchd daemon `product-backup-retention`
(`hosts/forge/product-backup-retention.nix`, daily 12:15, log
`/var/log/product-backup-retention.log`, state and receipt
`/var/lib/product-backup-retention/`). It never runs on Black: Black's writer key
stays append-only and Black holds no prune or compact authority or timer. Atlas
is excluded too: it is the agent workstation, and parent-account access was
deliberately revoked there. Forge is always on, and its retention key and Borg
passphrase are root-only (`0400`) SOPS secrets in
`secrets/product-backup-retention.yaml`. That file is encrypted only to the operator
age key and Forge's SSH host key, **never to Black**. The `nschmid10049` account
(T3 Code, GitHub runners) cannot read those secrets without the account's sudo
password. That password is the remaining boundary, and the retention key can delete
the whole repository, so treat Forge root as backup-deletion authority.

The retention key is a separate SSH key on the parent account. Its forced command
is exact-repository but **not** append-only:
`command="borg-1.4 serve --restrict-to-repository /home/product-backup/repo",restrict ssh-ed25519 … product-backup-retention@forge`.

Each run (`scripts/storage-box/retention.py`) fails closed:

1. It lists the archives and compares them with the survivors from the previous run.
   Any archive that disappeared without this job pruning it (for example a
   logical delete through the append-only writer) stops the run before any prune
   or compact. Compacting would make such a deletion permanent. Investigate and
   recover from Borg transaction history first.
2. It prunes each series `NAME-<export timestamp>` with
   `--glob-archives 'NAME-[0-9]*' --keep-within 30d`. Current deployments
   (`hosts/black/convex/deployments.nix`) also get `--keep-last 1`. It derives
   series from the repository, so a retired deployment (for example
   `modus-dev`/`modus-prod`) is deleted entirely once its archives pass 30 days. An
   archive outside that naming scheme fails the run. Prune only marks archives
   deleted; the compaction in step 3 is what frees their data on the Storage Box.
3. It records the survivors as the next baseline. It then compacts, except in
   dry-run mode and on the first run without a baseline.
4. It writes `last-run.json` (pruned names, survivor count, compaction, and
   survivors older than 30 days).

Failure exits non-zero and logs. Pushover delivery is wired
(`services.productBackupRetention.pushover.enable`, secret
`product-backup-retention/alert-config`, JSON
`{"pushover":{"token":"APP_TOKEN","user":"USER_KEY"}}`, sent by
`scripts/storage-box/alert.py`) but stays off: there is no application token.
Black moved to June alerts on 2026-11-24; whether Forge follows is open. Until then,
or an external monitor reads the receipt, check the log after deployment and weekly.
Missed runs (Forge at the FileVault screen after a reboot) only delay pruning and
are not reported.

Only june-prod holds customer (Kanzlei) data (see below). Its bootstrap archives
from 2026-11-04 are the oldest and are deleted on the first real run after
2026-12-04.

### Activate (operator, from the Mac)

The Mac holds maintenance access and the operator SOPS key. Never paste the key or
passphrase into chat or command arguments.

```bash
umask 077; d=$(mktemp -d)
ssh-keygen -t ed25519 -N '' -C product-backup-retention@forge -f "$d/retention"
# Authorize it with the exact-repository, non-append-only forced command (port 23).
scp -P 23 u710483@u710483.your-storagebox.de:.ssh/authorized_keys "$d/authorized_keys"
cp "$d/authorized_keys" "$d/authorized_keys.before"
printf 'command="borg-1.4 serve --restrict-to-repository /home/product-backup/repo",restrict %s\n' \
  "$(cat "$d/retention.pub")" >> "$d/authorized_keys"
diff "$d/authorized_keys.before" "$d/authorized_keys"   # exactly one added line
scp -P 23 "$d/authorized_keys" u710483@u710483.your-storagebox.de:.ssh/authorized_keys
# Restriction check: a sibling path must fail with "Repository path not allowed".
BORG_RSH="ssh -i $d/retention -o IdentitiesOnly=yes" borg list --remote-path=borg-1.4 \
  ssh://u710483@u710483.your-storagebox.de:23/./product-backup/test-repo; echo "exit $?"
# Encrypt key + existing passphrase to the operator and Forge only (not Black).
cd path/to/agent-infra   # your checkout, on the PR branch
{ echo 'product-backup-retention:'; echo '  ssh-key: |'; sed 's/^/    /' "$d/retention"
  printf '  passphrase: '; sops -d --extract '["product-backup"]["passphrase"]' secrets/product-backup.yaml | jq -Rs .
} > "$d/plain.yaml"
sops --encrypt --input-type yaml --output-type yaml \
  --age age1numtshsamwmzmz4crn50hkrm3rysp4t026d6w6wt75x027vv8eaqmkvtfr,age1hzmltzdv2auelnsuy9r95sjt0674srenfgptz0uj023pqjxr7pjs96uqgx \
  "$d/plain.yaml" > secrets/product-backup-retention.yaml
rm -rf "$d"
```

`age1numt…` is the operator recipient already on `secrets/product-backup.yaml`, and
`age1hzml…` is `ssh-to-age` of Forge's `/etc/ssh/ssh_host_ed25519_key.pub`.
`age1qevku…` (Black) is deliberately absent. Commit the encrypted file and set
`services.productBackupRetention.enable = true` (still `dryRun = true`) in
`hosts/forge/configuration.nix`. After CI and merge, switch Forge and run once:

```bash
ssh -t nschmid10049@forge "sudo /run/current-system/sw/bin/darwin-rebuild switch --flake github:NicolaiSchmid/agent-infra/<rev>#forge"
ssh -t nschmid10049@forge "sudo launchctl kickstart system/org.nixos.product-backup-retention; sleep 120; sudo tail -n 120 /var/log/product-backup-retention.log; sudo cat /var/lib/product-backup-retention/last-run.json"
```

Review the "Would prune" lines. Then set `dryRun = false`, merge, and switch again.
The first real run prunes but defers compaction because it has no baseline yet. Later
runs compact after the deletion check. Record the first real run in the acceptance
evidence. To pause, set `enable = false`. To prune by hand, use the same
credentials from the Mac with the command in step 2 above, and `borg compact` only
after the same check.

### Other copies of product data

Only june-prod holds customer data, checked 2026-11-19 by table names and record counts,
not content. june-dev holds test data, and the modus-gateway deployments hold gateway
usage metadata with no Kanzlei content (see the TOMs). The rules below apply to every
deployment. All of them run in `convex-NAME-backup` on Black (`hosts/black/convex.nix`)
after each successful export.

- Garage `NAME-backups/daily`: the local copy of every backup ZIP, kept as long as
  the off-host copy. ZIPs older than 30 days are deleted; the newest is always kept.
  This is a convenience copy, not off-host recovery. At june-prod's current size
  (about 240 MB a day) it needs about 7 GB.
- Garage `NAME-exports`: Convex's own export objects. Each one is the same ZIP as the
  daily backup. They are deleted after 14 days. On 2026-11-19 nothing had removed
  them; june-prod held 31, with full production exports from 2026-11-03.
- Garage `NAME-snapshot-imports`: upload files of finished snapshot imports, deleted
  after 14 days. On 2026-11-19 this was june-prod's 214 MB production migration
  snapshot (2026-11-03) and june-dev's three test fixtures (2026-10-30).

## Isolated restore acceptance (required before claiming recoverability)

Use a separate disposable host with no production network routes, DNS, webhooks,
email or payment access. Restore using escrowed credentials, not Black's files.
Select an archive, `borg check --verify-data REPOSITORY`, then in a private empty
directory `borg extract REPOSITORY::ARCHIVE`. With asymmetric payloads, decrypt
`payload.tar.age` using the Bitwarden-held private identity and unpack it in that
private directory first. Keep the private identity off Black. Run
`python3 scripts/storage-box/verify-restore.py DIRECTORY` from this repository.
Extract recovery.tar only on that isolated host; it contains live secrets.

For **each of six deployments** start a fresh isolated Convex and Garage using the
archived compose/config and matching pinned backend image (fetch approved images
before blocking egress). Restore instance/storage credentials from recovery.tar,
recreate buckets using archived provisioning configuration, generate/verify admin
access, and import `export.zip` with the matching Convex CLI's
`convex import --replace-all -y` against the isolated deployment. Keep endpoints
loopback-only and never use production URLs or an existing database.

Before the drill record known non-sensitive record IDs/counts and storage file
IDs/SHA256s from the export. After import query those records through the API,
compare counts and fields, fetch referenced blobs through Convex storage URLs and
compare SHA256s. Verify schema/functions deploy from the appropriate product
repository revision (agent-infra is infrastructure source, not product source),
instance secret/admin access, storage credentials and deployment ports/image.
Record source revision, archive ID, export timestamp, integrity result, record/blob
assertions, elapsed recovery time and operator in a private drill receipt. An empty
storage export needs an explicit no-blobs observation, not a fabricated blob test.
Destroy the isolated secrets/state afterwards. Archive integrity alone is not a
successful application restore. The archive checks and synthetic deletion test above have been collected; application-drill evidence must be reported separately.

For an automated data/config drill after archive extraction, use
`python3 scripts/storage-box/drill.py DIRECTORY --cli /path/to/convex/bin/main.js`.
Preload the exact archived image. This creates a capped disposable backend on a
Docker internal network, publishes no ports, imports into fresh state, restores
application environment variables, re-exports with storage, and compares every
record plus blob SHA256. `_storage.internalId` is backend-local and is excluded
from record comparison; public IDs, other metadata and bytes must match. No
application source/functions are deployed by this data drill, so it does not
prove custom application behavior or rebuild the original Garage server. Private
receipts include image/config/access results. Remove the private drill state and
logs after retaining the non-sensitive acceptance receipt.

## Implementation validation

Plan: reuse each completed storage-inclusive export → archive with encrypted
recovery material → publish last-success receipt → alert on stale receipts →
provision/test restrictions → measure a week → isolated application restore.
Local review covered fresh-export selection, fail-closed encryption/success, effective systemd/image and application-environment capture, asymmetric payload packaging,
credential separation, bounded sequential Borg access and product-only scope.
Default and enabled Black derivations evaluated (enabled evaluation used an empty
test-only SOPS file, not activation credentials). Six tests cover valid/invalid exports, failure/success receipts, age round-trip packaging, Pushover delivery failure and stale/missing/future success timestamps. The remote restriction and initial archive checks above passed. Final subaccount scheduling, public-recipient selection, external escrow and Pushover delivery remain activation gates. No full NixOS switch was made.
