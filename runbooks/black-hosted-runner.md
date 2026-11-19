# Hosted workflow runner on black (E5)

Prepared on 2026-11-18; **not deployed**. Since A1 (2026-11-18) the runner
reads bundles from the platform's artifact store on black instead of
downloading one pinned bundle from June; the store, its source repository and
builder are in [black-agent-source.md](black-agent-source.md), and both go
live in the one night deployment below. The service module enables
`hosted-runner-june-dev` and `hosted-runner-june-prod` at boot. Prod is on
since Nicolai Schmid's decision of 2026-11-19: the acceptance runs in June
prod, in the MODUS org, with synthetic agents and data only, because June
dev's Convex backend is in an out-of-memory restart loop. Real client data on
black stays blocked by O2 of June's runtime plan; the guard is that only staff
activate releases and create installations, through June's operator CLI
(internal functions, admin key). Each runner executes one delivery at a time
(O4); this is a limit for a second firm.

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
block. Write a local `june-prod-release.json` and `june-dev-release.json`
with exactly this shape:

```json
{
  "environment": {"image": "node@sha256:<pinned image digest>", "digest": "sha256:<environment digest>"}
}
```

The environment digest is the runner's `targetEnvironmentDigest(image)`, not
the image digest; eve-deployments `docs/agent-source.md` shows it. Compute it
from an eve-deployments checkout at the pinned revision after
`npm ci --ignore-scripts`:

```sh
node --input-type=module -e 'const {targetEnvironmentDigest} = await import(process.cwd() + "/src/target-artifact.ts"); console.log(targetEnvironmentDigest(process.argv[1]))' node@sha256:<pinned image digest>
```

Since 2026-11-19 both files pin the guest image of eve-deployments
`scripts/fixtures/gvisor-config.json` (the image its gVisor CI runs), with the
digest computed this way at the revision in `hosts/black/eve-deployments.nix`. For an E4
sandbox release, its bundle also pins the sandbox image; pre-pull that exact
image as well. Never substitute a mutable tag. Neither the runner nor the
builder fetches anything at run time; builds run offline in gVisor. Missing or
invalid selection fails startup. Replacing the pin requires stopping the runner
and the agent-source service, waiting for cleanup, and preserving their state;
unresolved custody must be reconciled with the old pin before changing it.
Builds made under the old pin report the old environment and need a new commit.

```sh
for d in june-prod june-dev; do
  scp $d-release.json root@black:/root/hosted-runner/$d-release.json.new &&
  ssh root@black "install -o root -g root -m 0600 /root/hosted-runner/$d-release.json.new /root/hosted-runner/$d-release.json && rm /root/hosted-runner/$d-release.json.new"
done
```

## Night deployment and rollback

E5 and A1 go live together, in one agreed night window, for June prod and
June dev. Before the window, by day and without touching services: the runner
bundle and the environment pins above, the agent-source keys and toolchain
source ([black-agent-source.md](black-agent-source.md), "Before the night"),
and the June environment variables. Run after the PR is merged, CI is green
and disk headroom is recovered. No fleet rebuild is needed. Run the entire
block as one command: the local shell aborts on failed merge checks, and one
remote shell owns every credential and disk check, build, image pull,
snapshot and switch. Any failure before the switch prevents it, including
space dropping below 25 GiB after the builds or image pull. Do not extract
the switch into a separate command.

June prod's checks are strict. June dev's only warn, because its Convex
backend is in an out-of-memory restart loop (2026-11-19): a missing dev
credential, a dev unit that fails to start or a dev 401 probe that fails is
reported, and the deployment continues. A switch that fails only on
`*-june-dev*` units counts as a warning too; any other failed unit stops the
block. The last step, run from the operator's machine on the tailnet, checks
that E2B's refused ports and the prod source API no longer answer there.

```sh
sh <<'DEPLOY'
set -eu
INFRA_PR=__INFRA_PR__
test "$(gh api repos/NicolaiSchmid/agent-infra/pulls/$INFRA_PR --jq .merged)" = true
INFRA_REV=$(gh api repos/NicolaiSchmid/agent-infra/pulls/$INFRA_PR --jq .merge_commit_sha)
ssh root@black sh -s -- "$INFRA_REV" <<'REMOTE'
set -eu
infra_rev=$1
warn() { echo "Warning (june-dev, not fatal): $*" >&2; }
require_space() {
  available_kib=$(df --output=avail -k / | tail -1)
  test "$available_kib" -ge 26214400 || {
    echo 'Deployment stopped: black requires at least 25 GiB free.' >&2
    exit 1
  }
}
# 401 without a key from the deployment's Convex container to its source API.
# The service hashes its toolchain before it listens: allow two minutes.
probe() {
  code=000
  for attempt in $(seq 60); do
    code=$(docker exec "convex-$1-backend-1" curl -s -o /dev/null -w '%{http_code}' "http://host.docker.internal:$2/v1/head" || true)
    test "$code" = 401 && return 0
    sleep 2
  done
  echo "$1: source API answered $code, expected 401." >&2
  return 1
}
for file in /root/hosted-runner/june-prod-runner.key /root/hosted-runner/june-prod-release.json \
  /root/agent-source/june-prod-source.key /root/agent-source/june-prod-builder.key; do
  test -s "$file" || { echo "Deployment stopped: $file is missing." >&2; exit 1; }
done
for file in /root/hosted-runner/june-dev-runner.key /root/hosted-runner/june-dev-release.json \
  /root/agent-source/june-dev-source.key /root/agent-source/june-dev-builder.key; do
  test -s "$file" || warn "$file is missing; its units will fail to start."
done
# The runner refuses any other shape, but only after the switch restarted Docker.
jq -e 'keys == ["environment"]' /root/hosted-runner/june-prod-release.json > /dev/null ||
  { echo 'Deployment stopped: june-prod-release.json must hold only {environment}.' >&2; exit 1; }
jq -e 'keys == ["environment"]' /root/hosted-runner/june-dev-release.json > /dev/null 2>&1 ||
  warn 'june-dev-release.json must hold only {environment}.'
df -h / /nix /var/lib/docker
docker system df
require_space
# Fails unless the toolchain source was added by day; roots the result.
nix build --out-link /nix/var/nix/gcroots/agent-source-toolchain "github:NicolaiSchmid/agent-infra/$infra_rev#agent-source-toolchain"
nixos-rebuild build --flake "github:NicolaiSchmid/agent-infra/$infra_rev#black"
require_space
image=$(jq -er .environment.image /root/hosted-runner/june-prod-release.json)
docker pull "$image"
dev_image=$(jq -er .environment.image /root/hosted-runner/june-dev-release.json 2>/dev/null || true)
if test -n "$dev_image" && test "$dev_image" != "$image"; then
  docker pull "$dev_image" || warn "could not pull $dev_image."
fi
# For E4, pull the bundle's exact sandbox image here too, before the final gate.
require_space
readlink -f /nix/var/nix/profiles/system > /root/hosted-runner/pre-e5-system
docker ps --format '{{.Names}}' > /root/hosted-runner/pre-e5-containers
# NIGHT WINDOW ONLY: interrupts ALL Docker containers.
switched=0
nixos-rebuild switch --flake "github:NicolaiSchmid/agent-infra/$infra_rev#black" || switched=$?
if test "$switched" != 0; then
  failed=$(systemctl list-units --failed --plain --no-legend | cut -d' ' -f1)
  echo "Switch exited $switched; failed units: $failed" >&2
  if test -z "$failed" || printf '%s\n' "$failed" | grep -qv -- '-june-dev'; then
    echo 'Deployment stopped after the switch: decide on rollback below.' >&2
    exit 1
  fi
  warn 'the switch failed on june-dev units only.'
fi
systemctl is-active docker firewall convex-june-prod hosted-runner-june-prod agent-source-june-prod
docker info --format '{{json .Runtimes.runsc}}'
docker ps --format '{{.Names}}'
probe june-prod 7422
systemctl is-active convex-june-dev hosted-runner-june-dev agent-source-june-dev || warn 'units not active.'
probe june-dev 7421 || warn 'source API probe failed.'
for unit in hosted-runner-june-prod agent-source-june-prod hosted-runner-june-dev agent-source-june-dev; do
  journalctl -u "$unit" -n 30 --no-pager
done
df -h /
REMOTE
# From the tailnet: E2B's refused ports and the prod source API must not answer.
for port in 3003 5007 7422; do
  if curl -s -m 5 -o /dev/null "http://black.takaya-buri.ts.net:$port/"; then
    echo "Port $port answers on the tailnet." >&2
    exit 1
  fi
done
DEPLOY
```

Compare containers with `/root/hosted-runner/pre-e5-containers`; confirm June
dev/prod RPC and HTTP health and actual guest `HostConfig.Runtime=runsc`.
The runner journals must report readiness. Do not consider E5 the complete live
acceptance: a staff-started release in the MODUS org must still make funded
MODUS inference with run-linked usage, request a real tool approval, resume,
survive runner death mid-effect without repeating the write, sleep across
guests, and finish with output in June. All acceptance data remains synthetic.

If rollout fails, stop the runners and wait for cleanup. Preserve state,
credentials, private bundle and selected pins. A failure of the agent-source
service alone does not need this: stop its units and fix forward
([black-agent-source.md](black-agent-source.md), "Rollback"). Roll back to the saved system
generation (a second dockerd restart also interrupts all containers):

```sh
ssh root@black 'set -e; systemctl stop hosted-runner-june-prod agent-source-june-prod hosted-runner-june-dev agent-source-june-dev; previous=$(cat /root/hosted-runner/pre-e5-system); "$previous/bin/switch-to-configuration" switch'
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
