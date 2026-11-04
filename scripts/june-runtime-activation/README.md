# June-only runtime activation

Preparation only: do not apply until publication/readback, pull access, source
review/CI and parent serialization gates are complete. Live receipts stay in
the existing June ledger. Stage the exact reviewed helper and verify its SHA256
remotely. Check is read-only and requires the exact candidate already local:

```
/nix/store/l9k0anq0z7zz81zcwy035jfwap9ga6rl-python3-3.13.13/bin/python3 /var/tmp/june-runtime-activation.py check
```

Candidate build41885580642 manifest is
`sha256:fc6f1b18d8e4ed81b9f77dffe131bc58c333c85557f51501324418fd6a2eb2bb`,
config `sha256:3109a3fa67890843b147771d480eea8106af011cae79084b3c330153c35aba5b`.
Publication and anonymous pull access are separate gates; install no credentials
on Black. Retain the original image locally and verify the candidate local ID
after a digest-pinned pull. A pull is not activation. Never rebuild or move a tag
to resolve a mismatch.

The helper reconciles the current original image, action800/HTTP1800, capacity
and existing timeout overlay against occupied runtime settings. Its new overlay
changes only June image and action1800/HTTP2100. The 1805-second outer deadline
leaves 295 seconds of HTTP headroom. Only convex-june-prod.service is reloaded;
Compose runs backend with --no-deps --pull never. No fleet switch. Data, mounts
and options, resources, unrelated environment, network/ports, other identities
and route bytes must remain equal. Existing capacity and timeout files stay.

After review/CI and fresh parent coordination confirming no backend deploy,
long action or token refresh is active, execute with the fresh reviewed digest:

```
/nix/store/l9k0anq0z7zz81zcwy035jfwap9ga6rl-python3-3.13.13/bin/python3 /var/tmp/june-runtime-activation.py apply FRESH_REVIEWED_FINGERPRINT
```

Drift aborts. Do not blindly retry partial failure. Private rollback files are
under /var/lib/client-data/june-runtime-fc6f1b18 (directory700/files600). Never
attach raw snapshot/environment/credentials to chat/logs/artifacts. Rollback:

```
/nix/store/l9k0anq0z7zz81zcwy035jfwap9ga6rl-python3-3.13.13/bin/python3 /var/tmp/june-runtime-activation.py rollback
```

Rollback removes only this helper's exact new drop-in and restores original
image plus800/1800 via the retained baseline, with occupied data. Interrupted
Compose rename recovery uses only saved original ID; no volume deletion.
Unrelated drift stops recovery for inspection. Sanitized receipt includes ID,
StartedAt, health, timeouts and preservation result. Retain old image/private
receipt until acceptance completes.

Healthy startup is not nested-action acceptance. Coordinate exactly one real
605-second parent/child action through a no-retry long-lived client, unique IDs,
authenticated completion/error/start/end/duration for BOTH, no replay, no
DB/storage writes, explicit completion or cancellation/cleanup receipts.
Reconcile existing IDs after disconnect before another invocation. Preserve X
tokens; invoke no provider action for this probe.

## Immutable source chain

Upstream bb31399c8704ceb6c19003936f6e144375b2c3bc; callback source
46334ae29a556b3c492219ae0b1bb1a6888ed107; build workflow
b9e7e9cbeac9bffc4fffc8408a73b3fabff83cc1/run41885580642; isolated acceptance
29a36ca524af9ff4432e6da0f29ed8223e53a6ca/run41891541466; publication workflow
8e741c031c656fa2300396cb52baa94de1fee3f9/run41893296684. The selector uses
only the preserved manifest above. Version endpoint `unknown` is not provenance.
Rollback reference remains original
`ghcr.io/convex/convex-backend:bb31399c8704ceb6c19003936f6e144375b2c3bc@sha256:207cf95def42f01614b6e3af0af5c20d0dcaa5ff2adf258ee7bc9555576644fa`.

Black uses Docker29's containerd snapshotter: image inspect Id and Descriptor
identify the manifest digest, unlike the validation runner's config-based ID.
Preflight requires exact manifest Id/Descriptor/RepoDigest and streams Docker's
local OCI save to hash both manifest and config blobs, requiring the manifest's
config reference to equal the independently accepted config digest. No image
identity guard is skipped. This is a read-only local export, not a rebuild.
