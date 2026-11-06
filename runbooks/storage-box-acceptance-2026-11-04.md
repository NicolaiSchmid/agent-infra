# Storage Box recovery acceptance — 2026-11-04

These are bootstrap Borg-encrypted archives from completed storage-inclusive
Garage exports. Public-key payload protection and the final subaccount schedule
are not yet activated. No whole-Atlas recovery is implied.

Borg 1.4.4 full remote data check and extraction/config integrity checks passed.
The six archives were imported into fresh backends on isolated Docker internal
networks on Atlas, with no published ports or production state mounts. Exact
archived backend images and instance credentials were used. Application environment
variables were restored and compared. Re-exported records and blob SHA256s matched.
Backend-local `_storage.internalId` was excluded; public file IDs and other metadata
were retained. Custom application functions were not redeployed by this data drill.
The original Garage server was not rebuilt. This is a data/config recovery drill,
not independent recovery-key escrow acceptance.

Results (records exclude storage metadata; timings start after archive extraction
and image preload, so they are not end-to-end recovery-time guarantees):

- june-dev: 2 records; 1 blobs; application environment matched; 9.59 seconds.
- june-prod: 92,389 records; 241 blobs; application environment matched; 273.51 seconds.
- modus-dev: 0 records; 0 blobs; application environment matched; 12.04 seconds.
- modus-gateway-dev: 2,282 records; 0 blobs; application environment matched; 9.38 seconds.
- modus-gateway-prod: 159 records; 0 blobs; application environment matched; 9.48 seconds.
- modus-prod: 0 records; 0 blobs; application environment matched; 12.47 seconds.

June production needed a retry after the first verification connection reset
under the initial 1.5 GiB cap. The successful retry used at most 3 GiB / two CPUs.
All created containers/networks were removed; plaintext drill datasets and logs
were removed after preserving private acceptance receipts.

Append-only behavior was tested on a separate synthetic remote repository:
logical archive deletion and compact returned 0; repository deletion returned 2.
Rollback to transaction 5 restored the deleted fixture with SHA256
`8809a2d0dc11e1e8f9cd857f91d0e4cff6de621e1e427c1e6f89f852d7cc0244`.
This is recoverable append-only history, not immutable storage.

Compressed ZIP measurement covered the five available June production daily
exports: 430,115,231 input bytes, 401,504,802 Borg-added bytes. Three were empty
before migration; the two populated snapshots were 214,001,152 and 216,111,361
bytes. The latter added 188,119,049 bytes after the previous snapshot. More
steady daily observations are needed; randomized age ciphertext will not reuse
those cross-version chunks.

Remaining activation inputs: assigned subaccount username; public recipient and
private-key escrow/independent decryption; existing Pushover application token.
The user declined email and creation of a new Pushover app. Final writer access
must be restricted to the exact repository and the temporary Atlas parent-account
authorization removed, leaving retention authority on the operator’s Mac.
