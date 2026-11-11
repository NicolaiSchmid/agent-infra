# Storage Box recurring backup activation — 2026-11-11

Recurring storage-inclusive Convex backups are active on Black, using the existing
parent account with an exact-repository append-only writer command. The operator
selected the recorded Mac RSA SSH public key for age payload encryption.
This updates the bootstrap-only status in the [2026-11-04 acceptance record](storage-box-acceptance-2026-11-04.md).

## Deployment and verification

The deployed infrastructure source is `e1892ae28ee0590ba9127a935b0f27bb1b78ecb0`,
from the [Storage Box implementation (#68)](https://github.com/NicolaiSchmid/agent-infra/pull/68).
Nix and callback CI checks passed; CodeRabbit was skipped. Codex review found no
remaining actionable defects. Black built that exact revision before activation.

The switch applied the backup units, SOPS delivery and hourly freshness timer.
No Convex restart was listed in dry activation or observed during the switch.
D-Bus reload timed out, as earlier reloads had; D-Bus remained active/running.
The switch therefore returned a warning status rather than a clean exit. The
initial freshness check correctly failed on stale bootstrap receipts; after the
fresh writes below it passed. The D-Bus reload issue is separate from backup
operation and was not repaired by this change.

Each existing daily service was run serially and returned success. Each remote
archive was listed through the restricted writer and contained exactly one member,
`payload.tar.age`. A subsequent full `borg check --verify-data` returned success.

| Deployment | Accepted encrypted archive |
| --- | --- |
| june-dev | `june-dev-1794397408898892647` |
| june-prod | `june-prod-1794397440285605978` |
| modus-gateway-dev | `modus-gateway-dev-1794397449488082487` |
| modus-gateway-prod | `modus-gateway-prod-1794397456483003304` |

The authoritative schedule derives from `hosts/black/convex.nix`: daily exports
with randomized delay. The health timer checks current deployment receipts hourly.
Retired MODUS deployment archives remain historical material, not scheduled jobs.

## Access separation

The writer successfully listed the product repository; a request for the sibling
test repository failed with `Repository path not allowed`. The forced command is
`borg-1.4 serve --append-only --restrict-to-repository /home/product-backup/repo`.
Both OpenSSH and RFC4716 entries for the temporary Atlas maintenance key were
removed while preserving the Mac maintenance key and restricted writer entry.
A subsequent Atlas maintenance-key login was rejected. Black has no prune or
compaction timer; operator maintenance remains separate. Append-only history is
recoverable transaction history, not immutable storage.

## Remaining operator acceptance

The operator has not yet confirmed downloading/decrypting the recovery kit on the
Mac or preserving recovery material outside Black and Atlas. The new age payloads
have not been independently decrypted/restored; the earlier data/config restore
drills do not prove this new recipient's independent recovery path.

Only a Pushover user key is available. Its API also requires an application token;
no app creation was authorized, and push delivery remains unavailable. Local
freshness checks do not substitute for push delivery or an external dead-man
monitor, which remains unconfigured. Retention review/compaction stays on the
operator Mac; no long-term retention automation or quota alert is claimed.
