# Convex internal callback headers deadline

A nested Node action can outlive the Node fetch client's default 300-second
response-headers deadline even when the supported action execution limit is
1800 seconds. This patch is against exact upstream
`bb31399c8704ceb6c19003936f6e144375b2c3bc`.

`fix.patch` adds a dispatcher used only by `SyscallsImpl.actionCallback`, with
`headersTimeout: 0`. The owning action's existing AbortSignal and `dispose()`
still cancel callbacks. Body and connect deadlines retain their Undici defaults;
storage fetches and application/global fetch are untouched. Action callbacks
retain `retryTransient: false`. The already-locked Undici 7.29.1 moves from dev
to runtime dependencies; its dependency resolution is unchanged.

## Focused verification

```sh
cd patches/convex-callback-headers
npm ci --ignore-scripts
npm test
```

The harness downloads SHA256-checked source inputs from the exact commit and
replays the patch. It executes the patched TypeScript and real `SyscallsImpl`
against local servers. Tests cover delayed headers past an accelerated deadline,
body and TLS-connect deadlines, caller abort, dispose cancellation, and exactly
one action request after a response failure or a disconnected established socket.
No real 300-second wait or production probe is needed. The small harness uses
published Convex value helpers; it does not replace full upstream validation.

Upstream instructions are `npm-packages/AGENTS.md`: `just format-js`,
`just lint-js`, `just turbo run build --filter=node-executor...`, and
`npm run test -- <file>`; dependency changes normally use `just update-js`.
The patch's importer-only pnpm lock change moves the existing exact version.
Run the normal workspace checks in the admitted source-build checkout before
publishing an image. Full monorepo installation/build is not part of this small
harness and has not been run during source preparation.

## Source-managed backend build (not started)

The executor's `local.cjs` is embedded into the Rust binary by
`crates/isolate/build.rs`, then extracted by `crates/node_executor/src/local.rs`.
A filesystem replacement of extracted JS is not a persistent source fix.
Upstream documents the Docker build in `self-hosted/docker-build/README.md`.

After normal resource admission, resolve and review the upstream cargo-chef
builder's **linux/amd64 digest**, then prepare an empty isolated build directory:

```sh
./patches/convex-callback-headers/prepare-build.sh "$BUILD_DIR" "$BUILDER_IMAGE_AT_SHA256"
```

This prepares source only. It pins upstream commit, patch hash, builder digest
and the exact existing runtime image, writing `callback-build-inputs.json` and
`Dockerfile.callback`. The latter preserves upstream build stages and replaces
only `/convex/convex-local-backend` in the pinned runtime base. OS/Node, entrypoint,
key generator, ports and image defaults remain inherited from that base.

Once admitted and source checks pass, the build command is:

```sh
docker buildx build --platform linux/amd64 \
  --file "$BUILD_DIR/Dockerfile.callback" \
  --build-arg VERGEN_GIT_SHA=bb31399c8704ceb6c19003936f6e144375b2c3bc \
  --build-arg VERGEN_GIT_COMMIT_TIMESTAMP=2026-10-24T08:39:29Z \
  --tag "$CANDIDATE_TAG" --load "$BUILD_DIR"
```

Retain the input manifest, upstream/infra source commits, build logs, patched
bundle hash and resulting image digest. The inherited OCI revision identifies
the upstream base; `io.convex.callback.patch.sha256` identifies the modification.
No new image digest exists yet. The builder contains networked package/tool
installation steps, so this is a repeatable pinned-source recipe, **not a claim
of bit-for-bit reproducibility**. Record resolved dependencies and tool versions;
use an approved pinned mirror/snapshot if that stronger property is required.

Admission needs a Linux amd64 builder with Docker BuildKit, network access to
Rust/npm/tool/package registries, and space for a full Rust/V8 backend build and
caches. Upstream uses an `xlarge` self-hosted runner; its recipe does not provide
a defensible numeric RAM/disk bound. Measure/reserve those through the normal
build queue before starting, cap concurrent compilation, and keep this work off
the live Black host. No heavy build or image push is authorized by this recipe.

## June-only selection

June production's entry in `hosts/black/convex/deployments.nix` selects this
build by registry digest, together with action1800/HTTP2100; other
deployments keep the shared template's image. It has run there since
2026-11-04. A new build is a reviewed change to that single digest, deployed
by the normal `nixos-rebuild switch`; never a placeholder, a moved tag or a
change to the shared image pin. Keep live acceptance facts in the June ledger,
not in this source file.

## June execution and HTTP envelopes

June production's entry sets `NODE_ACTION_USER_TIMEOUT_SECS=1800` and
`HTTP_SERVER_TIMEOUT_SECONDS=2100`. Other instances retain their existing values.
At exact upstream `crates/local_backend/src/lib.rs:208`, the local executor's
outer process/response deadline is the action ceiling plus 5 seconds: 1805s.
The 2100s server request envelope leaves 295s above that deadline for request
overhead. It does not promise 30-minute browser or proxy connections.
Traefik source config sets read/idle timeouts to1800s; those are request-read and
connection-idle limits, not a response-write allowance. Read-only inspection of the active Traefik arguments found no write-timeout
override. Pinned Traefik v3.7.16 `pkg/config/static/static_config.go:201-224`
leaves response-write and forwarding response-header deadlines at zero (disabled).
Recheck any dynamic transport override before release; no Traefik change is
included. Short client deadlines remain possible.
Long waits and delegated jobs must use the application's persisted continuation
implementation. Coordinate its reviewed deployment and one scoped backend
activation with the parent; do not apply this planned config ahead of that work.
