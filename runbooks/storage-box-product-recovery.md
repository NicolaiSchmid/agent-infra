# Encrypted off-host product recovery

Scope: the six Black Convex deployments, their storage-inclusive snapshot ZIPs,
instance/storage secrets and deployment source. This is **not an Atlas VM backup**,
nor full E2B, ClickHouse, Garage, or host disaster recovery. Garage daily copies on
Black are not off-host recovery. No disk deletion or repartition is needed here.

## Provision and activate (currently blocked: no Storage Box provisioned)

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
   Keep the separate unrestricted retention key and parent account off Black.
4. In a disposable repository with those same restrictions create two archives,
   attempt archive delete/prune/compact/repository delete with the writer, then
   inspect using retention authority. Record exit codes and recoverability from
   Borg transaction history. Append-only may permit logical deletion while
   retaining segments: it is **not immutable storage**. Reject activation if the
   writer can reclaim old data or escape its repository. Retention authority must
   never compact until unexpected deletions have been investigated.
5. Use private secret input on a trusted machine and SOPS-edit
   `secrets/secrets.yaml` (never paste secrets into chat or command arguments).
   Add `product-backup/writer-key`, `product-backup/passphrase`, and
   `product-backup/alert-curl-config`. The latter is a curl config with a private
   HTTPS webhook URL and static alert body, e.g. request POST/data; test delivery.
   Verify Black is a SOPS recipient. No plaintext secrets belong in Nix/store.
6. Set `services.productBackup.enable = true`, `repository` (SSH URL with
   `:23/./`) and `knownHosts` (verified `[host]:23` key). Evaluate and deploy
   through the normal host change procedure. Run each existing
   `convex-NAME-backup.service` manually, serially. A Borg warning/failure fails
   the service and does not advance the success receipt. Local Garage upload
   follows off-host archiving; it may therefore wait/fail with the remote job.

No repository, credential, host key or alert endpoint has been invented. Existing
local SSH config has no Storage Box entry; SOPS integration exists but no backup
credentials are supplied by this change.

## Operations and capacity

Hourly health checks alert for each missing or >36h-old successful off-host archive,
including first activation. Test missing/stale receipts and webhook outage; systemd
failure/journal must also be watched by the operator. An external dead-man monitor
is required to detect Black being down (a host cannot alert when powered off).
Do not mark activation complete until that monitor observes daily completion.

Root-only `/var/lib/product-backup/NAME.json` records ZIP compressed/uncompressed
bytes, SHA256 and Borg JSON statistics (original/compressed/deduplicated bytes).
Compare at least 7 daily exports per deployment and aggregate actual repository
size using retention credentials. Compressed ZIPs can deduplicate poorly. Size for
14 daily + 8 weekly + 6 monthly archives plus 30% headroom using measured added
bytes, not raw database size. Cache and manifests add local space; ZIPs are
hardlinked into a private temporary directory, not copied. Only one Borg job runs
at once; no local history is accumulated.

From the recovery workstation only, review archive lists and then use
`borg prune --dry-run --list --glob-archives 'NAME-*' --keep-daily 14 --keep-weekly 8 --keep-monthly 6 REPOSITORY`
for each name. Review before real prune, then compact explicitly. Never install
this authority or a prune/compact timer on Black. Retained append-only segments
consume capacity until authorized compaction. Alert on provider quota independently.

## Isolated restore acceptance (required before claiming recoverability)

Use a separate disposable host with no production network routes, DNS, webhooks,
email or payment access. Restore using escrowed credentials, not Black's files.
Select an archive, `borg check --verify-data REPOSITORY`, then in a private empty
directory `borg extract REPOSITORY::ARCHIVE`. Run
`python3 scripts/storage-box/verify-restore.py DIRECTORY` from this repository.
Extract recovery.tar only on that isolated host; it contains live secrets.

For **each of six deployments** start a fresh isolated Convex and Garage using the
archived compose/config and matching pinned backend image (fetch approved images
before blocking egress). Restore instance/storage credentials from recovery.tar,
recreate buckets using archived provisioning configuration, generate/verify admin
access, and import `export.zip` with the matching Convex CLI's
`convex import --replace --yes` against the isolated deployment. Keep endpoints
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
successful application restore. Actual remote capacity/deletion/restore evidence
cannot be collected until provisioned and activated.

## Implementation validation

Plan: reuse each completed storage-inclusive export → archive with encrypted
recovery material → publish last-success receipt → alert on stale receipts →
provision/test restrictions → measure a week → isolated application restore.
Local review covered fresh-export selection, fail-closed encryption/success,
credential separation, bounded sequential Borg access and product-only scope.
Default and enabled Black derivations evaluated (enabled evaluation used an empty
test-only SOPS file, not activation credentials). Python tests cover valid/invalid
exports and failure/success receipt behavior. The remote restriction, sizing and
restore acceptance gates above remain outstanding; no live deployment was made.
