# Hosted workflow runner on black (E5)

Prepared on 2026-11-18; **not deployed**. The service module enables
`hosted-runner-june-dev` at boot and defines `hosted-runner-june-prod` without a
boot dependency. Do not start prod manually: pilot acceptance and the decision
about real client data on black must come first (O2). Use test data only. Each
runner executes one delivery at a time (O4); this is a limit for a second firm.

The trusted native process has a separate system user per deployment, only
supplementary Docker access (root-equivalent), no login or Convex admin key.
The key and release selection are systemd credentials. The key remains at
`/root/hosted-runner/<deployment>-runner.key`, root:root, 0600. Never copy it
into a release JSON, Nix expression, command argument or environment file.
The JSON credential has only public release pins. Systemd supplies an
owner-readable credential copy, compatible with the runner's private-file checks.

RPC is `EVE_JUNE_CONVEX_URL=https://june-dev.convex.modusservice.com`; HTTP
actions use `EVE_JUNE_HTTP_URL=https://june-dev-site.convex.modusservice.com`.
Prod uses the corresponding `june-prod` names. The runner key is passed by
`controlPlane.runnerKeyFile`, never an environment variable.

Persistent state is `/var/lib/hosted-runner-june-dev` (prod has its own path):
`locks/` contains flock files and dirty/recovery journals, `artifacts/` is the
digest-checked June cache, and `tmp/` contains broker sockets. Do not delete
these paths to clear a failed restart. The unit preserves the flock helper on
SIGTERM and waits for confirmed cleanup; stop has no timeout. A stuck cleanup
requires operator inspection, not automatic deletion of evidence. Ten failed
starts in ten minutes trip systemd's start limit; after resolving the cause,
use `systemctl reset-failed hosted-runner-june-dev` and start it again.

The runner has 512 MiB RAM, no swap, one CPU and 64 tasks. Guests retain the
upstream per-release limits, `--runtime runsc`, no network, no capabilities,
read-only root and no host credentials. Docker puts guests in black's existing
`client-data.slice` (4 GiB / 3 CPUs shared with demo services); the runner unit's
limits do not bound Docker-created guests. gVisor uses the same 2026-11-02
release and flags as eve-deployments CI: systrap and `--host-uds=open` for the
scoped broker socket. Docker's default runtime stays unchanged.

## Disk and maintenance prerequisites

On 2026-11-18, read-only checks found **11 GiB free of 953 GiB (99% used)**.
Docker held 6.454 GB of images, only 417 MB reclaimable; no build cache.
Do not pull or build guest images at that level. Recover headroom first, without
blind Docker pruning or deleting recovery journals. The operational minimum
for this rollout is 25 GiB free, then recheck after the build and image pull.
This buffer is a deployment gate, not a disk quota.

The runsc archive is about 62 MiB compressed and 161 MiB installed, plus the
Nix closure (including Node 24, potentially shared). The runner bundle is about
180 KB. A pinned Node image takes additional Docker space; inspect its actual
unpacked size. The S2 sandbox image was measured at 368 MiB, but its final
registry publication/digest is not supplied here. Image versions accumulate
until deliberately removed. June's artifact cache is bounded to 256 MiB per
instance; Nix old generations and image layers need extra headroom.

**The first switch changes Docker's runtime registration and restarts dockerd,
interrupting every container on black, including June dev/prod Convex, Garage,
Traefik and E2B. Run only in an agreed night maintenance window, never during
the day.** Budget 1–5 minutes of application downtime; this is an estimate,
not a measurement. Backends may need longer to recover. Graceful runner cleanup
can delay a later switch; investigate a stuck stop before forcing anything.

## Provision the private native bundle

The public infra repository must not vendor the private eve-deployments source.
The unit verifies a SHA-256-pinned bundle before each start. PR
https://github.com/NicolaiSchmid/eve-deployments/pull/105 supplies that CI artifact.
Merge both PRs through GitHub merge commits before deployment. These commands
are for the operator's authenticated workstation; they have not been run on black.
Retain the artifact privately before GitHub's artifact retention expires.

```sh
EVE_REV=98690a849440934094bc555765518c26ebff0e0d
EVE_RUN=44336554525
EVE_SHA256=bc5f114f837e5afedb9fd73b226ac4cc462de2b1db41dc5a15168348f35e9231
test "$(gh api repos/NicolaiSchmid/eve-deployments/actions/runs/$EVE_RUN --jq .head_sha)" = "$EVE_REV"
test "$(gh api repos/NicolaiSchmid/eve-deployments/actions/runs/$EVE_RUN --jq .conclusion)" = success
bundle_dir=$(mktemp -d)
gh run download "$EVE_RUN" --repo NicolaiSchmid/eve-deployments --name native-runner --dir "$bundle_dir"
(cd "$bundle_dir" && sha256sum --check SHA256SUMS)
test "$(sha256sum "$bundle_dir/runner.mjs" | cut -d' ' -f1)" = "$EVE_SHA256"
ssh root@black "install -d -m 0755 /var/lib/hosted-runner /var/lib/hosted-runner/releases /var/lib/hosted-runner/releases/$EVE_REV"
scp "$bundle_dir/runner.mjs" root@black:/root/hosted-runner/runner.mjs.new
ssh root@black "install -o root -g root -m 0444 /root/hosted-runner/runner.mjs.new /var/lib/hosted-runner/releases/$EVE_REV/runner.mjs && rm /root/hosted-runner/runner.mjs.new"
```

## Select the dev pilot release

Select the CI-uploaded test workflow in June dev first. No release has been
chosen by E5. Copy its actual artifact digest, entrypoint and environment
identity into a local `june-dev-release.json` with this shape:

```json
{
  "artifact": {"digest": "sha256:<uploaded bundle digest>", "entrypoint": "<bundle entrypoint>"},
  "environment": {"image": "node@sha256:<pinned image digest>", "digest": "sha256:<June release environment digest>"}
}
```

The environment digest is the runner's `targetEnvironmentDigest(image)`, not
the image digest. Use the value admitted with the June release. For an E4
sandbox release, its bundle also pins the sandbox image; pre-pull that exact
image as well. Never substitute a mutable tag. The runner downloads the June
bundle by digest; it does not build customer code on black. Missing or invalid
selection fails startup. Replacing the selection requires stopping the runner,
waiting for cleanup, and preserving its state; unresolved custody must be
reconciled with the old pins before changing them.

```sh
scp june-dev-release.json root@black:/root/hosted-runner/june-dev-release.json.new
ssh root@black 'install -o root -g root -m 0600 /root/hosted-runner/june-dev-release.json.new /root/hosted-runner/june-dev-release.json && rm /root/hosted-runner/june-dev-release.json.new'
```

## Night deployment and rollback

Run after both PRs are merged, CI is green and disk headroom is recovered.
Set `INFRA_PR` to this infra PR's number. No fleet rebuild is needed.

```sh
INFRA_PR=<agent-infra PR number>
test "$(gh api repos/NicolaiSchmid/agent-infra/pulls/$INFRA_PR --jq .merged)" = true
INFRA_REV=$(gh api repos/NicolaiSchmid/agent-infra/pulls/$INFRA_PR --jq .merge_commit_sha)
ssh root@black 'df -h / /nix /var/lib/docker; docker system df; test "$(df --output=avail -k / | tail -1)" -ge 26214400'
ssh root@black "nixos-rebuild build --flake github:NicolaiSchmid/agent-infra/$INFRA_REV#black"
# Pre-pull only the exact selected images, after the disk gate above.
ssh root@black 'docker pull "$(jq -er .environment.image /root/hosted-runner/june-dev-release.json)"'
# Also pull the exact sandbox image from the bundle, if this release uses E4.
ssh root@black 'test "$(df --output=avail -k / | tail -1)" -ge 26214400; readlink -f /nix/var/nix/profiles/system > /root/hosted-runner/pre-e5-system; docker ps --format "{{.Names}}" > /root/hosted-runner/pre-e5-containers'
# NIGHT WINDOW ONLY: interrupts ALL Docker containers.
ssh root@black "nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra/$INFRA_REV#black"
ssh root@black 'systemctl is-active docker convex-june-dev convex-june-prod hosted-runner-june-dev; docker info --format "{{json .Runtimes.runsc}}"; docker ps --format "{{.Names}}"; journalctl -u hosted-runner-june-dev -n 50 --no-pager; df -h /'
```

Compare containers with `/root/hosted-runner/pre-e5-containers`; confirm June
dev/prod RPC and HTTP health and actual guest `HostConfig.Runtime=runsc`.
The runner journal must report readiness. Do not consider E5 the complete live
acceptance: a staff-started CI release must still make funded MODUS inference
with run-linked usage, request a real tool approval, resume, survive runner death
mid-effect without repeating the write, sleep across guests, and finish with
output in June. All pilot data remains synthetic.

If rollout fails, stop the dev runner and wait for cleanup. Preserve state,
credentials, private bundle and selected pins. Roll back to the saved system
generation (a second dockerd restart also interrupts all containers):

```sh
ssh root@black 'systemctl stop hosted-runner-june-dev; previous=$(cat /root/hosted-runner/pre-e5-system); "$previous/bin/switch-to-configuration" switch'
```

That restores the active runtime configuration. To restore the boot default too,
use `nixos-rebuild switch --rollback` only if the immediately previous generation
is the saved one; otherwise switch the system profile to the saved generation
deliberately. Never remove dirty markers or claim cleanup from a timeout. If
cleanup hangs, reconcile the guest and June custody before proceeding.

## Verification boundaries

E5 checks the rendered black units, Docker configuration and packaged runsc with
targeted Nix builds/evaluation. Full black/fleet validation belongs to CI, never
an Atlas full build or typecheck. Runner targeted tests cover origins, private
file configuration, flock ownership and crash journals. Packaging is built in
eve-deployments CI. No switch, runner start, image pull or real workflow has
been performed on black by this change. Disk headroom, actual black/gVisor
operation, June credentials/backend compatibility and live acceptance remain
deployment checks.
