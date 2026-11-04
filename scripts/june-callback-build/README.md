# Admitted June callback candidate build

This manual-only workflow consumes PR60's exact reviewed source commit
`46334ae29a556b3c492219ae0b1bb1a6888ed107`, without changing that branch.
The resource owner admitted one Linux amd64 build on the existing
`ubicloud-standard-16` pool (16 vCPU/64 GiB). Compilation is capped at 12 jobs
inside the Docker build; the job limit is 120 minutes. No Atlas/Black build,
production data, registry credentials or deployment is used.

Cargo-chef and Dockerfile frontend are pinned to resolved Linux amd64 digests;
checkout/artifact actions are pinned to commit IDs. Upstream pins Rust to
`nightly-2026-06-28`, Node to 24.22.1, pnpm to 11.15.1, and locked dependencies.
Upstream apt, rustup self-update and cargo-install-just remain networked inputs;
this is not a bit-for-bit reproducible toolchain. Resolved versions are logged.
The runtime base remains PR60's exact original image digest.

The exact revision's Justfile has no `format-js` or `lint-js` recipes despite
its AGENTS.md naming them. The build therefore runs its actual dprint formatter
on changed files, a frozen workspace install, the filtered executor TypeScript
and bundle build, and the focused transport tests directly through Vitest (the
package's broader test command references test fixtures absent from this tree).
No unavailable lint or integration suite is claimed to have passed.

After independent review and ordinary CI, the workflow must exist on main for
GitHub to enable dispatch. Dispatch exactly once at the reviewed workflow commit:

```sh
gh workflow run june-callback-candidate.yml --repo NicolaiSchmid/agent-infra \
  --ref WORKFLOW_COMMIT \
  -f source_commit=46334ae29a556b3c492219ae0b1bb1a6888ed107
```

The workflow retains the OCI archive for seven days, and source/workflow pins,
Dockerfile/input hashes, build log (including patched bundle SHA256), OCI digest,
resource timing and disk usage for fourteen days. `/usr/bin/time -v` measures the
buildx client, not the Docker daemon's peak RSS; it must not be interpreted as
compiler peak memory. The fixed runner bounds total available RAM.

The OCI candidate has no registry publication or package-write permission.
Inspect its immutable manifest digest, perform isolated ABI/startup/runtime
acceptance, then arrange a reviewed registry publication and June-only selector.
A successful build never authorizes activating the old image with new settings.
