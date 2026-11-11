# Encrypted off-host product recovery

Scope: the six Black Convex deployments, their storage-inclusive snapshot ZIPs,
instance/storage secrets and deployment source. This is **not an Atlas VM backup**,
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
Independent Mac decryption/key escrow remains unverified. Pushover delivery remains unavailable
without an application token, and no external dead-man monitor has been configured.
The hourly host check can report stale archives locally but is not push delivery.
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
   Keep the separate unrestricted retention key and parent account off Black.
4. In a disposable repository with those same restrictions create two archives,
   attempt archive delete/prune/compact/repository delete with the writer, then
   inspect using retention authority. Record exit codes and recoverability from
   Borg transaction history. Append-only may permit logical deletion while
   retaining segments: it is **not immutable storage**. Reject activation if the
   writer can reclaim old data or escape its repository. Retention authority must
   never compact until unexpected deletions have been investigated.
5. Use private secret input on a trusted machine and SOPS-edit
   `secrets/product-backup.yaml` (never paste secrets into chat or command arguments).
   The encrypted writer key and passphrase are already present. For Pushover,
   add `product-backup/alert-config` as a JSON string with
   `{"pushover":{"token":"APP_TOKEN","user":"USER_KEY"}}`, then enable
   `services.productBackup.pushover.enable`. Pushover requires both credentials;
   the operator supplied a user key but no application token and explicitly
   requested no new app. Push delivery remains disabled until an existing token
   is supplied. Email delivery was declined. Never treat journal checks as push
   delivery. Black is an encrypted-file recipient. No plaintext secrets belong
   in Nix/store.
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
including first activation, and send Pushover alerts only when configured. Test missing/stale receipts and delivery failure; systemd
failure/journal must also be watched by the operator. An external dead-man monitor
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
