# Storage Box 30-day retention — 2026-11-19

Decision (Nicolai Schmid, 2026-11-19): the off-host Borg repository
`product-backup/repo` keeps the newest 30 daily archives per deployment series
(`--keep-daily 30`, no weekly or monthly), pruned and compacted automatically. This
matches MODUS's AVV Anlage 2 and the DSFA ("täglich verschlüsselt … gesichert und dort
30 Tage aufbewahrt"). The design is in the
[recovery runbook](storage-box-product-recovery.md#retention-30-days).

## Status

Implemented, **not yet active**. The Forge daemon is in the configuration with
`enable = false`, `dryRun = true`. No retention key exists on the Storage Box yet.
`secrets/product-backup-retention.yaml` is not yet created. No host switch was made,
and no archive was pruned or compacted.

## Dry run against the real repository

Read-only, 2026-11-19 ~18:00 CET, from Black through its append-only writer, under
Black's backup lock (`/var/lib/product-backup/lock`), Borg 1.4.4:
`borg prune --dry-run --list --glob-archives 'NAME-[0-9]*' --keep-daily 30` for every
series in the repository.

| Series | Archives | Oldest | Would prune |
| --- | --- | --- | --- |
| june-dev | 11 | 2026-11-04 (bootstrap) | none |
| june-prod | 9 | 2026-11-04 (bootstrap) | none |
| modus-gateway-dev | 11 | 2026-11-04 (bootstrap) | none |
| modus-gateway-prod | 11 | 2026-11-04 (bootstrap) | none |
| modus-dev (retired) | 2 | 2026-11-04 (bootstrap) | none |
| modus-prod (retired) | 2 | 2026-11-04 (bootstrap) | none |

Every series is below 30 daily archives, so nothing is due yet. The oldest archive
is 15 days old. Pruning starts once a series has more than 30 days with an archive
(around 2026-12-10 for the current deployments, later for june-prod).

Observed while doing this:

- june-prod has no archive for 2026-11-17 or 2026-11-19. The 2026-11-19 run failed
  at 03:38 CET because the backend did not accept connections on 127.0.0.1:13220.
  `product-backup-health` has reported `Missing/stale off-host backup: june-prod`
  since that afternoon. No push delivery exists, so only the journal shows it.
- Only june-prod holds customer (Kanzlei) data. This was checked by table names
  and record counts in the newest exports, not content. june-dev holds test data,
  and the modus-gateway deployments hold gateway usage metadata. Retired
  `modus-dev`/`modus-prod` hold no records.
- Because of its gaps (2026-11-05..10, 11-17, 11-19), june-prod's 2026-11-04 bootstrap
  archives would survive `--keep-daily 30` until about 2026-12-13 (about 39 days).

## Other copies checked (Black Garage, 2026-11-19)

| Bucket | Customer data | Objects | Oldest with customer data | Within 30 days? |
| --- | --- | --- | --- | --- |
| june-prod-backups | yes | 14 | 2026-11-05 | yes, newest 14 kept |
| june-prod-exports | yes | 31 | 2026-11-03 (10-31..11-02 are empty, 906 bytes) | no pruning; over 30 days on 2026-12-03 |
| june-prod-snapshot-imports | yes | 1 (214 MB) | 2026-11-03 | no pruning; over 30 days on 2026-12-03 |
| june-dev-* | no (test data; imports 23–1,917-byte fixtures) | 14 / 23 / 3 | — | not bound |
| modus-gateway-*-* | no (usage metadata) | 14 / 22 / 0 each | — | not bound |

`/var/lib/product-backup/bootstrap` on Black is empty. Its Borg cache (112K) holds
no payload.

## Acceptance still to record

- Retention key authorized with the exact forced command, and the sibling-repository
  check rejected (exit code).
- First Forge dry-run log and `last-run.json`.
- First real run (prune list; compaction deferred), then the first compacting run.
