# Hosted workflow runner on black (E5)

Prepared on 2026-11-18; **not deployed**. Since A1 (2026-11-18) the runner
reads bundles from the platform's artifact store on black instead of
downloading one pinned bundle from June; the store, its source repository and
builder are in [black-agent-source.md](black-agent-source.md), and both go
live in the one night deployment below. The service module enables
`hosted-runner-june-dev` at boot and defines `hosted-runner-june-prod` without a
boot dependency. Do not start prod manually: pilot acceptance and the decision
about real client data on black must come first (O2). Use test data only. Each
runner executes one delivery at a time (O4); this is a limit for a second firm.

The trusted native process has a separate system user per deployment, only
supplementary Docker access (root-equivalent), no login or Convex admin key.
The key and release selection are systemd credentials. The existing keys and parent directory were verified on black on 2026-11-18.
The key remains at
`/root/hosted-runner/<deployment>-runner.key`, root:root, 0600. Never copy it
into a release JSON, Nix expression, command argument or environment file.
The JSON credential has only public release pins. Systemd 260 supplies readable
root-owned 0440 credentials. Pre-start runs as the service user and copies the
key into `/run/hosted-runner-<deployment>/runner-key` with mode 0600, satisfying
the runner's owner/private-file checks. The runtime directory is private and
systemd removes it when the unit stops. No key value enters the environment,
Nix store or logs.

RPC is `EVE_JUNE_CONVEX_URL=https://june-dev.convex.modusservice.com`; HTTP
actions use `EVE_JUNE_HTTP_URL=https://june-dev-site.convex.modusservice.com`.
Prod uses the corresponding `june-prod` names. The runner key is passed by
`controlPlane.runnerKeyFile`, never an environment variable.

Persistent state is `/var/lib/hosted-runner-june-dev` (prod has its own path):
`locks/` contains flock files and dirty/recovery journals, `artifact-cache/` is
the runner's private cache of bundles unpacked from the store (each verified by
digest), and `tmp/` contains broker sockets. The runner reads
`/var/lib/agent-artifacts/<deployment>` read-only through group
`agent-artifacts`. Do not delete
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

The runsc archive is about 72 MiB compressed and 162 MiB installed, plus the
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
The unit verifies a SHA-256-pinned bundle before each start. The pin (revision,
CI run, SHA-256) lives in `hosts/black/eve-deployments.nix`, shared with the
agent-source toolchain; the eve-deployments CI run's `native-runner` artifact
supplies the bundle. The runner reads the platform store from eve-deployments
E6 (PR https://github.com/NicolaiSchmid/eve-deployments/pull/109) on. These
commands run from an agent-infra checkout at the merged revision on the
operator's authenticated workstation; they have not been run on black. Retain
the artifact privately before GitHub's artifact retention expires.

```sh
sh <<'PROVISION'
set -eu
pin=hosts/black/eve-deployments.nix
EVE_REV=$(nix eval --raw -f "$pin" revision)
EVE_RUN=$(nix eval --raw -f "$pin" runner.run)
EVE_SHA256=$(nix eval --raw -f "$pin" runner.sha256)
test "$(gh api repos/NicolaiSchmid/eve-deployments/actions/runs/$EVE_RUN --jq .head_sha)" = "$EVE_REV"
test "$(gh api repos/NicolaiSchmid/eve-deployments/actions/runs/$EVE_RUN --jq .conclusion)" = success
bundle_dir=$(mktemp -d)
gh run download "$EVE_RUN" --repo NicolaiSchmid/eve-deployments --name native-runner --dir "$bundle_dir"
(cd "$bundle_dir" && sha256sum --check SHA256SUMS)
test "$(sha256sum "$bundle_dir/runner.mjs" | cut -d' ' -f1)" = "$EVE_SHA256"
ssh root@black 'set -e; test -d /root/hosted-runner; test -s /root/hosted-runner/june-dev-runner.key; test -s /root/hosted-runner/june-prod-runner.key'
ssh root@black "install -d -m 0755 /var/lib/hosted-runner /var/lib/hosted-runner/releases /var/lib/hosted-runner/releases/$EVE_REV"
scp "$bundle_dir/runner.mjs" root@black:/root/hosted-runner/runner.mjs.new
ssh root@black "install -o root -g root -m 0444 /root/hosted-runner/runner.mjs.new /var/lib/hosted-runner/releases/$EVE_REV/runner.mjs && rm /root/hosted-runner/runner.mjs.new"
PROVISION
```

## Select the environment pin

The runner no longer pins an artifact: June's admission pins the digest per
run, and the runner reads that digest from the store and verifies it. The
release JSON holds only the environment pin, and the agent-source builder
reports the same file's pin with every build, so builds and runs agree. The
runner's pre-start refuses any other field, including a stale `artifact`
block. Write a local `june-dev-release.json` with exactly this shape:

```json
{
  "environment": {"image": "node@sha256:<pinned image digest>", "digest": "sha256:<environment digest>"}
}
```

The environment digest is the runner's `targetEnvironmentDigest(image)`, not
the image digest; eve-deployments `docs/agent-source.md` shows it. For an E4
sandbox release, its bundle also pins the sandbox image; pre-pull that exact
image as well. Never substitute a mutable tag. Neither the runner nor the
builder fetches anything at run time; builds run offline in gVisor. Missing or
invalid selection fails startup. Replacing the pin requires stopping the runner
and the agent-source service, waiting for cleanup, and preserving their state;
unresolved custody must be reconciled with the old pin before changing it.
Builds made under the old pin report the old environment and need a new commit.

```sh
scp june-dev-release.json root@black:/root/hosted-runner/june-dev-release.json.new &&
ssh root@black 'install -o root -g root -m 0600 /root/hosted-runner/june-dev-release.json.new /root/hosted-runner/june-dev-release.json && rm /root/hosted-runner/june-dev-release.json.new'
```

## Night deployment and rollback

E5 and A1 go live together, in one agreed night window, June dev only. Before
the window, by day and without touching services: the runner bundle and the
environment pin above, the agent-source keys and toolchain source
([black-agent-source.md](black-agent-source.md), "Before the night"), and the
June dev environment variables. Run after the PR is merged, CI is green and
disk headroom is recovered. No fleet rebuild is needed. Run the entire block
as one command: the local shell aborts on failed merge checks, and one remote
shell owns every credential and disk check, build, image pull, snapshot and
switch. Any failure prevents the switch, including space dropping below 25 GiB
after the builds or image pull. Do not extract the switch into a separate
command.

```sh
sh <<'DEPLOY'
set -eu
INFRA_PR=90
test "$(gh api repos/NicolaiSchmid/agent-infra/pulls/$INFRA_PR --jq .merged)" = true
INFRA_REV=$(gh api repos/NicolaiSchmid/agent-infra/pulls/$INFRA_PR --jq .merge_commit_sha)
ssh root@black sh -s -- "$INFRA_REV" <<'REMOTE'
set -eu
infra_rev=$1
require_space() {
  available_kib=$(df --output=avail -k / | tail -1)
  test "$available_kib" -ge 26214400 || {
    echo 'Deployment stopped: black requires at least 25 GiB free.' >&2
    exit 1
  }
}
for file in /root/hosted-runner/june-dev-runner.key /root/hosted-runner/june-dev-release.json \
  /root/agent-source/june-dev-source.key /root/agent-source/june-dev-builder.key; do
  test -s "$file" || { echo "Deployment stopped: $file is missing." >&2; exit 1; }
done
df -h / /nix /var/lib/docker
docker system df
require_space
# Fails unless the toolchain source was added by day; roots the result.
nix build --out-link /nix/var/nix/gcroots/agent-source-toolchain "github:NicolaiSchmid/agent-infra/$infra_rev#agent-source-toolchain"
nixos-rebuild build --flake "github:NicolaiSchmid/agent-infra/$infra_rev#black"
require_space
image=$(jq -er .environment.image /root/hosted-runner/june-dev-release.json)
docker pull "$image"
# For E4, pull the bundle's exact sandbox image here too, before the final gate.
require_space
readlink -f /nix/var/nix/profiles/system > /root/hosted-runner/pre-e5-system
docker ps --format '{{.Names}}' > /root/hosted-runner/pre-e5-containers
# NIGHT WINDOW ONLY: interrupts ALL Docker containers.
nixos-rebuild switch --flake "github:NicolaiSchmid/agent-infra/$infra_rev#black"
systemctl is-active docker convex-june-dev convex-june-prod hosted-runner-june-dev agent-source-june-dev
docker info --format '{{json .Runtimes.runsc}}'
docker ps --format '{{.Names}}'
# June dev's Convex container reaches the source API; without a key it answers 401.
test "$(docker exec convex-june-dev-backend-1 curl -s -o /dev/null -w '%{http_code}' http://host.docker.internal:7421/v1/head)" = 401
journalctl -u hosted-runner-june-dev -n 50 --no-pager
journalctl -u agent-source-june-dev -n 20 --no-pager
df -h /
REMOTE
DEPLOY
```

Compare containers with `/root/hosted-runner/pre-e5-containers`; confirm June
dev/prod RPC and HTTP health and actual guest `HostConfig.Runtime=runsc`.
The runner journal must report readiness. Do not consider E5 the complete live
acceptance: a staff-started CI release must still make funded MODUS inference
with run-linked usage, request a real tool approval, resume, survive runner death
mid-effect without repeating the write, sleep across guests, and finish with
output in June. All pilot data remains synthetic.

If rollout fails, stop the dev runner and wait for cleanup. Preserve state,
credentials, private bundle and selected pins. A failure of the agent-source
service alone does not need this: stop its units and fix forward
([black-agent-source.md](black-agent-source.md), "Rollback"). Roll back to the saved system
generation (a second dockerd restart also interrupts all containers):

```sh
ssh root@black 'set -e; systemctl stop hosted-runner-june-dev agent-source-june-dev; previous=$(cat /root/hosted-runner/pre-e5-system); "$previous/bin/switch-to-configuration" switch'
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

Focused regressions (no real deployment):

```sh
python3 scripts/hosted-runner-runbook.test.py
# On Atlas, after downloading the pinned private bundle above:
python3 scripts/hosted-runner-credential.test.py --runner /path/to/runner.mjs
```

The first check executes the actual deployment block with fake SSH, disk,
Docker and Nix commands, including low initial/final space and command failures.
It runs in public CI. The second uses a temporary systemd unit on Atlas,
a synthetic key and inventory-only fake Docker. It verifies root-owned 0440
credential input, the service-owned 0600 runtime copy, real packaged-runner
readiness and clean idle shutdown. It requires passwordless sudo and the
private CI artifact; public infra CI cannot download that private artifact.
