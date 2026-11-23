# Agent source, builder and artifact store on black (A1)

Prepared on 2026-11-18; **not deployed**. `hosts/black/agent-source.nix`
declares the platform service from eve-deployments E6 for each June
deployment: a source API with one bare git repository holding every agent, a
builder that compiles one agent folder in rootless gVisor without network, and
the content-addressed artifact store the hosted runner reads. The contract
(listen addresses, API, store layout, June calls) is eve-deployments
`docs/agent-source.md`; the scope and decisions are June's
`.plans/2026-11-18-agent-source-on-platform.md`. Both instances are on, like
the E5 runner: Nicolai Schmid decided on 2026-11-19 to run the acceptance in
June prod, in the MODUS org, because June dev's Convex backend is in an
out-of-memory restart loop. Use synthetic agents and data only: real client
data on black stays blocked by O2 of June's runtime plan. The guard is that
release activation and installation are internal June functions, reached only
by staff through the operator CLI with the deployment's admin key
(`apps/june/convex/hostedRuns/README.md` in June).

## What runs

Names below use `<d>` for the deployment, `june-dev` or `june-prod`.

| Item | june-dev | june-prod | Notes |
|---|---|---|---|
| Service | `agent-source-june-dev.service` | `agent-source-june-prod.service` | API and build queue, user `agent-source`, `MemoryMax=3G`, `TasksMax=512` |
| Listen | `127.0.0.1:7421`, `172.17.0.1:7421` | `127.0.0.1:7422`, `172.17.0.1:7422` | docker0, which `host.docker.internal` resolves to in June's Convex containers |
| Firewall | accept 7421 on `cvx-13210` only | accept 7422 on `cvx-13220` only | the deployment's Convex bridge (`cvx-<cloudPort>`); new tailnet connections dropped by `tailnet-refuse.nix`; no Traefik route, no public address. `IPAddressDeny=any` with loopback and `172.16.0.0/12` allowed backs this up |
| Repository | `/var/lib/agent-source/june-dev/repo.git` | `/var/lib/agent-source/june-prod/repo.git` | created before the first start (`ExecStartPre`), which also sets the pre-receive hook (pushes to `refs/heads/main` only) and the force-push and delete refusals on every start; `work/` beside it is build scratch, wiped at start |
| Store | `/var/lib/agent-artifacts/june-dev` | `/var/lib/agent-artifacts/june-prod` | `agent-source:agent-artifacts`, setgid 2750; `hosted-runner-*` read it through group `agent-artifacts` |
| Keys | `/root/agent-source/june-dev-{source,builder}.key` | `/root/agent-source/june-prod-{source,builder}.key` | systemd credentials; the builder key is June's `HOSTED_BUILDER_KEY`, the source key becomes `HOSTED_SOURCE_KEY` once June's authoring tools read it |
| Environment pin | `/root/hosted-runner/june-dev-release.json` | `/root/hosted-runner/june-prod-release.json` | the runner's file ([black-hosted-runner.md](black-hosted-runner.md)), read by both services |
| June | `http://127.0.0.1:13211` | `http://127.0.0.1:13221` | the deployment's Convex HTTP actions on loopback; the builder never uses the public network |
| Timers | `agent-source-<d>-gc.timer` daily, `agent-source-<d>-git.timer` weekly | same | GC asks June which digests are referenced and deletes nothing if June cannot answer; `git gc --auto` and `git fsck` |
| Backup | June dev's nightly product backup | June prod's | `git bundle create --all` of the repository inside the backup lock, as `agent-source/repo.bundle` in `recovery.tar`; every bundle the same archive's Convex snapshot references, verified, as `agent-artifacts/` in `recovery.tar` (see "Backup and restore") |
| Toolchain | `nix build .#agent-source-toolchain` | eve-deployments at the pin in `hosts/black/eve-deployments.nix`, `npm ci --ignore-scripts`, pinned model catalog; rooted at `/nix/var/nix/gcroots/agent-source-toolchain` |
| Push | `agent-source@black`, login shell `git-shell` | tailnet only, see "First commit" |

None of this restarts Docker. The E5 runner's first switch does, so both go
live in the one night window of
[black-hosted-runner.md](black-hosted-runner.md), "Night deployment and
rollback", with its 25 GiB disk gates.

## Before the night

These steps change no service and can run by day. Never print, copy or paste
the key values; only files hold them.

1. **Keys.** On black, create both keys of both deployments once (black has
   no `openssl`; the value is 64 printable characters). Existing files are
   kept:

   ```sh
   ssh root@black 'set -eu; umask 077; install -d -m 0700 /root/agent-source
   for d in june-dev june-prod; do
     for kind in source builder; do
       file=/root/agent-source/$d-$kind.key
       test -e "$file" || { head -c 48 /dev/urandom | base64 -w0 > "$file"; chmod 0400 "$file"; }
     done
   done
   stat -c "%A %U:%G %s %n" /root/agent-source/*'
   ```

2. **June environment.** June's J9 (June PR #1435) reads the builder key as
   `HOSTED_BUILDER_KEY`; June declares no `HOSTED_SOURCE_KEY` or
   `HOSTED_SOURCE_URL` yet (its later authoring tools will, and reach the API
   at `http://host.docker.internal:<port>`). Set the builder key in each
   deployment's Convex from the file, through the endpoint
   `npx convex env set` uses, then list the names (not values) to confirm.
   The admin API is the deployment's `cloudPort`: 13210 for dev, 13220 for
   prod. Run once per deployment (`d=june-prod port=13220`, then
   `d=june-dev port=13210`):

   ```sh
   ssh root@black "d=june-prod port=13220; "'set -eu; umask 077; header=$(mktemp)
   trap "rm -f $header" EXIT
   printf "Authorization: Convex %s\n" "$(cat /var/lib/client-data/secrets/convex-$d-admin-key)" > "$header"
   jq -n --rawfile b /root/agent-source/$d-builder.key \
     "{changes: [{name: \"HOSTED_BUILDER_KEY\", value: \$b}]}" |
     curl -fsS -o /dev/null -H @"$header" -H "content-type: application/json" --data-binary @- \
       http://127.0.0.1:$port/api/update_environment_variables
   jq -n "{path: \"_system/cli/queryEnvironmentVariables\", args: {}, format: \"json\"}" |
     curl -fsS -H @"$header" -H "content-type: application/json" --data-binary @- \
       http://127.0.0.1:$port/api/query | jq -c "[.value[].name | select(startswith(\"HOSTED_\"))]"'
   ```

   On 2026-11-19 both deployments already held `HOSTED_BUILDER_KEY`,
   `HOSTED_RUNNER_KEY` and `HOSTED_RUN_STAFF_USER_IDS` equal to black's
   files (compared by hash on black); dev also holds an unused
   `HOSTED_SOURCE_KEY`.

3. **Environment pins.** `/root/hosted-runner/june-prod-release.json` and
   `june-dev-release.json`, written as in
   [black-hosted-runner.md](black-hosted-runner.md), "Select the environment
   pin". Both services of a deployment refuse to start without its file.

4. **Toolchain source.** eve-deployments is private and this repository is
   public, so the toolchain's source reaches black's Nix store by hand, as a
   fixed-output path the derivation names by hash. From an agent-infra
   checkout at the merged revision, on a workstation with eve-deployments
   access, on the day of the deployment:

   ```sh
   sh <<'SOURCE'
   set -eu
   pin=hosts/black/eve-deployments.nix
   rev=$(nix eval --raw -f "$pin" revision)
   name=eve-deployments-$(printf %s "$rev" | cut -c1-12)
   work=$(mktemp -d)
   trap 'rm -rf "$work"' EXIT
   gh repo clone NicolaiSchmid/eve-deployments "$work/repo" -- --quiet --no-checkout
   mkdir "$work/$name"
   git -C "$work/repo" archive "$rev" | tar -x -C "$work/$name"
   test "$(nix hash path "$work/$name")" = "$(nix eval --raw -f "$pin" sourceHash)"
   tar -C "$work" -cf - "$name" | ssh root@black "set -eu; d=\$(mktemp -d); trap 'rm -rf \$d' EXIT
     tar -x -C \$d; nix-store --add-fixed --recursive sha256 \$d/$name"
   SOURCE
   ```

   The night block builds the toolchain from it and fails before any switch
   if the path is missing.

## Night deployment

One block, together with E5: [black-hosted-runner.md](black-hosted-runner.md),
"Night deployment and rollback". It checks the credential files, builds
and roots the toolchain, builds the system, switches, and checks that
`agent-source-june-prod` is active and that June prod's Convex container gets
401 from the API without a key; the same checks for June dev only warn. By
hand:

```sh
ssh root@black "docker exec convex-june-prod-backend-1 curl -s -o /dev/null -w '%{http_code}\n' http://host.docker.internal:7422/v1/head"
```

Anything but `401` (for example `000`, a timeout) means the firewall or the
listen address is wrong; `ss -ltnp | grep 7422` on black must show exactly
`127.0.0.1:7422` and `172.17.0.1:7422` (dev: 7421, `convex-june-dev-backend-1`).
From the tailnet the port must not answer:
`curl -m 5 http://black.takaya-buri.ts.net:7422/v1/head` fails.
The journal line `agent-source listening` names the toolchain identity.

## First commit over ssh

On the tailnet, Tailscale SSH (`--ssh` on black) answers port 22 under the
tailnet policy and maps `agent-source` to the local user; OpenSSH, with
Nicolai's admin key, admits `agent-source` only from tailnet addresses
(`Match User agent-source Address` in `agent-source.nix`). Either way the
login shell is `git-shell`. Over OpenSSH that leaves clone, fetch and push.
Tailscale SSH, however, serves sftp/scp and port forwarding itself and ignores
the `Match` block, so a login as `agent-source` over Tailscale SSH can read
and write what that user can: the repository directly (past the hook below)
and its services' credentials. This is a known gap; the fix is a separate
push user without credential access, a later step. The tailnet SSH policy is
unchanged.

The repository exists after the service's first start. Pushes may update
`refs/heads/main` only: a pre-receive hook from the Nix store refuses every
other ref (branches, tags) and deleting `main`, and `receive.denyNonFastForwards`
refuses force-pushes. The build API builds only commits on `main` (409
otherwise). One folder per agent. The 2026-11-19 acceptance uses
June prod (MODUS org, synthetic agents only); for dev use `june-dev` and port
7421:

```sh
git clone agent-source@black:/var/lib/agent-source/june-prod/repo.git june-prod-agents
cd june-prod-agents
git symbolic-ref HEAD refs/heads/main   # the empty repository has no branch yet
mkdir -p agents/hello-agent/agent
# package.json, agent/ and optionally hosted.json; dependencies only eve and ai
# at the toolchain's versions (eve-deployments docs/agent-source.md, "Builder").
git add agents && git commit -m "feat(hello-agent): first synthetic agent"
git push origin main
```

Then request the build on black; it answers `202` while queued, then `200`
with the digest. Request it again: the same tree gives the same digest
(acceptance step 4 of the June plan). A failed build answers `422` with the
reason to every further request and is not built again; `-d '{"retry": true}'`
starts a new attempt of the same commit and keeps the failed one in the
attempt log (eve-deployments `docs/agent-source.md`, "Repository and API").

```sh
ssh root@black 'curl -s -X POST -H "authorization: Bearer $(cat /root/agent-source/june-prod-source.key)" \
  http://127.0.0.1:7422/v1/agents/hello-agent/builds -d "{}"'
journalctl -u agent-source-june-prod -n 50 --no-pager   # on black
```

A failed build writes the guest's log tail to the journal only.

## Backup and restore

The nightly `convex-<d>-backup` adds to its encrypted product archive:

- `agent-source/repo.bundle`, the repository, with `agent_source` (`bundled`,
  `empty` or `absent`) and the bundle's SHA-256 in `manifest.json`;
- `agent-artifacts/`, every bundle the archive's own Convex export references
  (active `hostedReleases`, open `hostedRuns`; June's
  `apps/june/convex/hostedRuns/builds.ts` `referenced`), in the store's layout
  (`objects/sha256/<2 hex>/<64 hex>`, their `builds/<agent>/<commit>.json` and
  `.reported`) plus `referenced.json`, the digest list. `manifest.json` records
  `agent_artifacts` (`bundled` or `none`) and `agent_artifact_digests`.

Each bundle is read without following symlinks and verified against its digest
before it enters the archive. A referenced bundle that is missing or damaged
fails that night's backup (no receipt, so the hourly health check reports it):
that archive could not resume the run. Rebuilding is no recovery path, because
a commit whose toolchain is gone is refused a rebuild (June keeps each commit's
first digest). Each archive is self-contained; bundles no longer referenced
leave the backup when the 30-day retention removes the archives that hold them.
Why and the decisions: June's `.plans/2026-11-23-hosted-artifact-durability.md`.

### Restore

Recovery of the archive follows
[storage-box-product-recovery.md](storage-box-product-recovery.md); after
`verify-restore.py` (which also checks every referenced bundle against its
digest and against the snapshot), with both services of the deployment
stopped (`agent-source-<d>`, `hosted-runner-<d>`):

```sh
d=june-prod   # or june-dev
tar -xf recovery.tar agent-source agent-artifacts
git clone --mirror agent-source/repo.bundle /var/lib/agent-source/$d/repo.git
git -C /var/lib/agent-source/$d/repo.git config receive.denyNonFastForwards true
git -C /var/lib/agent-source/$d/repo.git config receive.denyDeletes true
git -C /var/lib/agent-source/$d/repo.git remote remove origin
chown -R agent-source:agent-source /var/lib/agent-source/$d/repo.git
# Bundles: verified against their digests before anything is written, then
# written through the store's flushed path. Run as the store's owner from the
# realised toolchain (rooted at /nix/var/nix/gcroots/agent-source-toolchain).
# node: the one the unit's start script runs.
start=$(systemctl show -p ExecStart --value agent-source-$d | grep -o '/nix/store/[^ ;]*' | head -1)
node=$(grep -o '/nix/store/[^ ]*/bin/node' "$start" | head -1)
chown -R agent-source agent-artifacts
runuser -u agent-source -- \
  "$node" /nix/var/nix/gcroots/agent-source-toolchain/scripts/agent-source.ts \
  restore /var/lib/agent-artifacts/$d "$PWD/agent-artifacts" \
  --expect "$PWD/agent-artifacts/referenced.json"
```

The next start sets the hook and the push settings again. `restore` refuses
the whole set when one object fails verification or a digest from
`referenced.json` is absent; records already in the store win, and running it
twice changes nothing. Then restore June's Convex snapshot from the same
archive, start the services, and check that each open run's digest resolves:
the runner reads the restored store by digest, no build runs. Bundles of
releases created after the archive's snapshot are not in it; their builds are
asked for again (same source and toolchain, same digest).

### Restore drill

Required before claiming that an open run survives a disaster, and after any
change to the backup or the store layout. Off black, on an isolated recovery
host, never against a live store:

1. Pick the newest archive of the deployment, extract and decrypt it as in
   [storage-box-product-recovery.md](storage-box-product-recovery.md), run
   `verify-restore.py <dir>`: it must print `referenced bundles verified`.
2. Restore the bundles into an empty scratch store with the `restore` command
   above (scratch path instead of `/var/lib/agent-artifacts/$d`); it prints
   `{"objects": [...], "records": n}` with exactly `agent_artifact_digests`.
3. For one digest of an open run, resolve it through the runner's resolver
   against the scratch store (eve-deployments `createArtifactResolver` over
   `storeArtifactRead`, as in `tests/agent-source-restore.test.ts`) and check
   the entrypoint.
4. Corrupt one byte of one restored bundle in a copy of the archive's
   `agent-artifacts/`: `restore` must refuse and write nothing.
5. Record date, archive name, digest count and the outcome in a dated
   acceptance note next to this runbook; delete the scratch copies.

On synthetic data the same chain runs in CI: agent-infra's
`scripts/storage-box/test_backup.py` (backup, extract, verify, tampered
archive refused) and eve-deployments' `tests/agent-source-restore.test.ts`
(restore into an empty store, resolve by digest, damaged backup refused). The
first drill on real archives has not run yet.

## Bump the eve-deployments pin

`hosts/black/eve-deployments.nix` holds the one revision of the runner bundle
and the toolchain. It pins eve-deployments PR #117's merge commit (`01189cc`,
2026-11-22), whose CI run is green, gVisor and native-runner jobs included: E6 (PR #109),
owner-writable toolchain copies in the builder (PR #111), the runner's
proxy-404 retry (PR #112), failed builds that stay failed with an explicit
retry and main-only builds (PR #113), a guest crash that ends its delivery
instead of the runner (PR #115, which June's delivery-failure count from June
PR #1455 reads), a 256 MiB default guest (PR #116), and guest CPU, memory
and network metering for June's usage ledger (PR #117).
To move it, change all of these in one agent-infra PR:

1. `revision`: the eve-deployments commit on `main`.
2. `sourceHash`: `nix hash path` of `git archive <revision>` unpacked into a
   directory named `eve-deployments-<first 12 hex>` (step 4 above, without
   the upload).
3. `npmDepsHash`: `nix run nixpkgs#prefetch-npm-deps -- <that directory>/package-lock.json`,
   or build `.#agent-source-toolchain` and copy the `got:` hash.
4. `runner.run` and `runner.sha256`: the CI run of that commit and the
   SHA-256 of its `native-runner` artifact's `runner.mjs` (check its
   `SHA256SUMS`).

Then provision the new runner bundle and toolchain source, build and root
the new toolchain before the switch (the night block's `nix build` line; the
service refuses to start without it), stop both services, wait for runner
cleanup, and switch. A bump alone changes neither Docker's runtime
registration nor the runsc package, so the switch restarts only the runner
and agent-source units, not dockerd, and needs no night window; confirm with
`nixos-rebuild build` that `docker.service` and `/etc/docker/daemon.json` are
unchanged before switching. Check that the guest image of eve-deployments
`scripts/fixtures/gvisor-config.json` and `src/target-artifact.ts` are
unchanged between the two revisions; if either changed, follow "Select the
environment pin" in [black-hosted-runner.md](black-hosted-runner.md) first. A toolchain change changes the
toolchain identity: existing commits keep their recorded digests, new builds
need new commits.

## Rollback

The agent-source service alone needs no system rollback and no Docker
restart. Stop its units; repository, store and keys stay:

```sh
ssh root@black 'systemctl stop agent-source-june-prod agent-source-june-prod-gc.timer agent-source-june-prod-git.timer'
```

(dev: the same units with `june-dev`).

Then fix forward in a new agent-infra change. A failed night deployment as a
whole rolls back to the saved generation as described in
[black-hosted-runner.md](black-hosted-runner.md), which restarts Docker again.
The deployments' environment variables can stay; unset them only to retire
the service.

## Verified and assumed

Read-only on black on 2026-11-18: docker0 is `172.17.0.1/16` (no carrier, but
the local route exists), June dev's Convex container sits on bridge
`cvx-13210` (`172.23.0.1`, `host.docker.internal:host-gateway`), its HTTP
actions listen on `127.0.0.1:13211`, `nixos-fw` has the E2B `cvx-+` and
`tailscale0` rules this follows, user namespaces are enabled
(`user.max_user_namespaces=253500`, kernel 6.18.38), Tailscale SSH is on, the
container image has `curl`, and nothing exists yet under
`/root/agent-source`, `/var/lib/agent-source` or `/var/lib/agent-artifacts`.

Read-only on black on 2026-11-19: June prod's Convex container sits on bridge
`cvx-13220` (`172.21.0.1`), which is also its default route (it is on
`garage` and `traefik-public` too), its HTTP actions listen on
`127.0.0.1:13221`, and its image has `curl`; June dev's default route is
`cvx-13210`. tailscaled's `ts-input` chain ran ahead of `nixos-fw` and
accepted all of `tailscale0`, so the `nixos-fw` refuse rules this followed
never matched; `tailnet-refuse.nix` replaces them.

On Atlas: the toolchain derivation builds to the path black evaluates, the
service from it answers 401 without and 200 with the key, both generated
configurations pass eve-deployments' own parsers, the sshd `Match` blocks
evaluate as intended (`sshd -T`), and the backup's bundle restores to the same
`main`.

Not exercised: a request from a Convex container through the new firewall
rule, rootless runsc under this unit's hardening on black, a git push through
Tailscale SSH into `git-shell`, the June environment endpoint call, and a
build's report to June dev.
