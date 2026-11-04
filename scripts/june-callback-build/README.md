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

## Formatter context correction

Upstream's deny-by-default `.dockerignore` omits root `dprint.json`. Preparation
now includes only that additional root file, verifies its exact upstream
bb31399 SHA256 `00a63c00cd2d6f5769238389632bfbd6be0b0d234fe54a77d37f365fe6b0ed68`,
and records config/context hashes in the input manifest. Its checksum-pinned
Prettier plugin and complete formatter settings remain unchanged. The formatter
check is retained. This invalidates `COPY . .` and subsequent build layers, not
the preceding dependency layers if a cache is available. Ephemeral runners do
not promise cache reuse, so a corrected attempt may repeat the full build.

## Isolated acceptance and publication path

`june-candidate-acceptance.yml` consumes only build run 41885580642, checks the
fixed archive and every blob digest, compares the exact amd64 base layers and
runtime config, then imports the candidate on an ephemeral Ubicloud runner.
It runs the binary loader/ldd and startup health with 4 CPU/8 GiB caps, no
network, no host mounts and empty bounded tmpfs data. The instance credential is
a public disposable test fixture. No production secrets, state or providers are
reachable. Compilation and registry publication are absent.

This proves only image identity, ABI and empty-data startup. The build's seven
focused tests prove callback transport behavior in the workspace, not a real
nested action in the resulting runtime. Isolated deployed synthetic nested-action
acceptance remains required before a production rollout.

After candidate acceptance, publish the verified OCI archive without rebuilding,
using `skopeo copy --preserve-digests oci-archive:... docker://ghcr.io/nicolaischmid/june-convex-backend:callback-b9e7e9c`
in a reviewed job with package-write permission limited to that job. Re-read the
registry manifest and require unchanged digest
`sha256:fc6f1b18d8e4ed81b9f77dffe131bc58c333c85557f51501324418fd6a2eb2bb`.
Only then update `hosts/black/convex/june-prod-image.nix` to that registry digest;
other instance image selectors remain unchanged. No registry publication or
selector change is included in this acceptance workflow.

The single later June activation must apply candidate image plus action1800 and
HTTP2100 together, after fresh parent serialization clearance. Prepare a new
independently reviewed drift-guarded helper from the then-current live identity;
preserve occupied data/mounts, image defaults, network/ports, capacity, unrelated
environment, key digests, route bytes and every other instance identity. Recreate
only June backend with Compose `--no-deps --pull never`. Keep a private exact
baseline/rollback receipt and the original image locally; rollback restores the
prior image and 800/1800 settings with the same data, including recovery from a
partially renamed Compose container. Do not reuse a stale activation fingerprint
or perform a fleet Nix switch. Source-selector review and concrete helper review
remain separate gates; this document is not an activation command.
