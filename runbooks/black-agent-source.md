# Agent source, builder and artifact store on black (A1)

Prepared on 2026-11-18; **not deployed**. `hosts/black/agent-source.nix`
declares the platform service from eve-deployments E6 for each June
deployment: a source API with one bare git repository holding every agent, a
builder that compiles one agent folder in rootless gVisor without network, and
the content-addressed artifact store the hosted runner reads. The contract
(listen addresses, API, store layout, June calls) is eve-deployments
`docs/agent-source.md`; the scope and decisions are June's
`.plans/2026-11-18-agent-source-on-platform.md`. June dev only: `june-prod` is
defined and off, like the E5 runner, until O2 allows real client data on
black. Use synthetic agents and data only.

## What runs

| Item | june-dev | Notes |
|---|---|---|
| Service | `agent-source-june-dev.service` | API and build queue, user `agent-source`, `MemoryMax=3G`, `TasksMax=512` |
| Listen | `127.0.0.1:7421`, `172.17.0.1:7421` | docker0, which `host.docker.internal` resolves to in June's Convex containers; prod uses port 7422 |
| Firewall | accept 7421 on `cvx-13210` only; refuse on `tailscale0` | June dev's Convex bridge (`cvx-<cloudPort>`); no Traefik route, no public address. `IPAddressDeny=any` with loopback and `172.16.0.0/12` allowed backs this up |
| Repository | `/var/lib/agent-source/june-dev/repo.git` | created on first start; `work/` beside it is build scratch, wiped at start |
| Store | `/var/lib/agent-artifacts/june-dev` | `agent-source:agent-artifacts`, setgid 2750; `hosted-runner-*` read it through group `agent-artifacts` |
| Keys | `/root/agent-source/june-dev-source.key`, `june-dev-builder.key` | systemd credentials; June's `HOSTED_SOURCE_KEY` and `HOSTED_BUILDER_KEY` |
| Environment pin | `/root/hosted-runner/june-dev-release.json` | the runner's file ([black-hosted-runner.md](black-hosted-runner.md)), read by both services |
| June | `http://127.0.0.1:13211` | June dev's Convex HTTP actions on loopback; the builder never uses the public network |
| Timers | `agent-source-june-dev-gc.timer` daily, `agent-source-june-dev-git.timer` weekly | GC asks June which digests are referenced and deletes nothing if June cannot answer; `git gc --auto` and `git fsck` |
| Backup | June dev's nightly product backup | `git bundle create --all` of the repository inside the backup lock, as `agent-source/repo.bundle` in `recovery.tar`; the store is not backed up |
| Toolchain | `nix build .#agent-source-toolchain` | eve-deployments at the pin in `hosts/black/eve-deployments.nix`, `npm ci --ignore-scripts`, pinned model catalog; rooted at `/nix/var/nix/gcroots/agent-source-toolchain` |
| Push | `agent-source@black`, login shell `git-shell` | tailnet only, see "First commit" |

None of this restarts Docker. The E5 runner's first switch does, so both go
live in the one night window of
[black-hosted-runner.md](black-hosted-runner.md), "Night deployment and
rollback", with its 25 GiB disk gates.

## Before the night

These steps change no service and can run by day. Never print, copy or paste
the key values; only files hold them.

1. **Keys.** On black, create both keys once (black has no `openssl`; the
   value is 64 printable characters):

   ```sh
   ssh root@black 'set -eu; umask 077; install -d -m 0700 /root/agent-source
   for kind in source builder; do
     file=/root/agent-source/june-dev-$kind.key
     test -e "$file" || head -c 48 /dev/urandom | base64 -w0 > "$file"
   done
   ls -l /root/agent-source'
   ```

2. **June dev environment.** June's J9 (June PR #1435) reads the same values
   as `HOSTED_SOURCE_KEY` and `HOSTED_BUILDER_KEY`. Set them in June dev's
   Convex deployment from the files, through the endpoint `npx convex env set`
   uses, then list the names (not values) to confirm. Not yet run on black:

   ```sh
   ssh root@black 'set -eu; umask 077; header=$(mktemp)
   trap "rm -f $header" EXIT
   printf "Authorization: Convex %s\n" "$(cat /var/lib/client-data/secrets/convex-june-dev-admin-key)" > "$header"
   jq -n --rawfile s /root/agent-source/june-dev-source.key --rawfile b /root/agent-source/june-dev-builder.key \
     "{changes: [{name: \"HOSTED_SOURCE_KEY\", value: \$s}, {name: \"HOSTED_BUILDER_KEY\", value: \$b}]}" |
     curl -fsS -o /dev/null -H @"$header" -H "content-type: application/json" --data-binary @- \
       http://127.0.0.1:13210/api/update_environment_variables
   jq -n "{path: \"_system/cli/queryEnvironmentVariables\", args: {}, format: \"json\"}" |
     curl -fsS -H @"$header" -H "content-type: application/json" --data-binary @- \
       http://127.0.0.1:13210/api/query | jq -c "[.value[].name | select(startswith(\"HOSTED_\"))]"'
   ```

   June's later authoring tools reach the API at
   `http://host.docker.internal:7421` (`HOSTED_SOURCE_URL`).

3. **Environment pin.** `/root/hosted-runner/june-dev-release.json`, written
   as in [black-hosted-runner.md](black-hosted-runner.md), "Select the
   environment pin". Both services refuse to start without it.

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
"Night deployment and rollback". It checks the four credential files, builds
and roots the toolchain, builds the system, switches, and checks that
`agent-source-june-dev` is active and that June dev's Convex container gets
401 from the API without a key:

```sh
ssh root@black "docker exec convex-june-dev-backend-1 curl -s -o /dev/null -w '%{http_code}\n' http://host.docker.internal:7421/v1/head"
```

Anything but `401` (for example `000`, a timeout) means the firewall or the
listen address is wrong; `ss -ltnp | grep 7421` on black must show exactly
`127.0.0.1:7421` and `172.17.0.1:7421`. From the tailnet the port must be
refused: `curl -m 5 http://black.takaya-buri.ts.net:7421/v1/head` fails.
The journal line `agent-source listening` names the toolchain identity.

## First commit over ssh

On the tailnet, Tailscale SSH (`--ssh` on black) answers port 22 under the
tailnet policy and maps `agent-source` to the local user; OpenSSH, with
Nicolai's admin key, admits `agent-source` only from tailnet addresses
(`Match User agent-source Address` in `agent-source.nix`). Either way the
login shell is `git-shell`, so only clone, fetch and push work. The
repository exists after the service's first start. Branch `main`, one folder
per agent, no force-push or branch deletion:

```sh
git clone agent-source@black:/var/lib/agent-source/june-dev/repo.git june-dev-agents
cd june-dev-agents
git symbolic-ref HEAD refs/heads/main   # the empty repository has no branch yet
mkdir -p agents/hello-agent/agent
# package.json, agent/ and optionally hosted.json; dependencies only eve and ai
# at the toolchain's versions (eve-deployments docs/agent-source.md, "Builder").
git add agents && git commit -m "feat(hello-agent): first synthetic agent"
git push origin main
```

Then request the build on black; it answers `202` while queued, then `200`
with the digest. Request it again: the same tree gives the same digest
(acceptance step 4 of the June plan).

```sh
ssh root@black 'curl -s -X POST -H "authorization: Bearer $(cat /root/agent-source/june-dev-source.key)" \
  http://127.0.0.1:7421/v1/agents/hello-agent/builds -d "{}"'
journalctl -u agent-source-june-dev -n 50 --no-pager   # on black
```

A failed build writes the guest's log tail to the journal only.

## Backup and restore

The nightly `convex-june-dev-backup` adds `agent-source/repo.bundle` to its
encrypted product archive and records `agent_source` (`bundled`, `empty` or
`absent`) and the bundle's SHA-256 in `manifest.json`. Recovery follows
[storage-box-product-recovery.md](storage-box-product-recovery.md); then, with
the service stopped:

```sh
git clone --mirror repo.bundle /var/lib/agent-source/june-dev/repo.git
git -C /var/lib/agent-source/june-dev/repo.git config receive.denyNonFastForwards true
git -C /var/lib/agent-source/june-dev/repo.git config receive.denyDeletes true
git -C /var/lib/agent-source/june-dev/repo.git remote remove origin
chown -R agent-source:agent-source /var/lib/agent-source/june-dev/repo.git
```

Artifacts come back by requesting builds again: same source and toolchain,
same digest. After a toolchain change June keeps each commit's first digest,
so a lost artifact needs a new commit.

## Bump the eve-deployments pin

`hosts/black/eve-deployments.nix` holds the one revision of the runner bundle
and the toolchain. It pins the merge commit of E6 (eve-deployments PR #109,
`2f407ae`, 2026-11-19). To move it, change all of these in one agent-infra PR:

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
cleanup, and switch. A toolchain change changes the
toolchain identity: existing commits keep their recorded digests, new builds
need new commits.

## Rollback

The agent-source service alone needs no system rollback and no Docker
restart. Stop its units; repository, store and keys stay:

```sh
ssh root@black 'systemctl stop agent-source-june-dev agent-source-june-dev-gc.timer agent-source-june-dev-git.timer'
```

Then fix forward in a new agent-infra change. A failed night deployment as a
whole rolls back to the saved generation as described in
[black-hosted-runner.md](black-hosted-runner.md), which restarts Docker again.
June dev's environment variables can stay; unset them only to retire the
service.

## Verified and assumed

Read-only on black on 2026-11-18: docker0 is `172.17.0.1/16` (no carrier, but
the local route exists), June dev's Convex container sits on bridge
`cvx-13210` (`172.23.0.1`, `host.docker.internal:host-gateway`), its HTTP
actions listen on `127.0.0.1:13211`, `nixos-fw` has the E2B `cvx-+` and
`tailscale0` rules this follows, user namespaces are enabled
(`user.max_user_namespaces=253500`, kernel 6.18.38), Tailscale SSH is on, the
container image has `curl`, and nothing exists yet under
`/root/agent-source`, `/var/lib/agent-source` or `/var/lib/agent-artifacts`.

On Atlas: the toolchain derivation builds to the path black evaluates, the
service from it answers 401 without and 200 with the key, both generated
configurations pass eve-deployments' own parsers, the sshd `Match` blocks
evaluate as intended (`sshd -T`), and the backup's bundle restores to the same
`main`.

Not exercised: a request from a Convex container through the new firewall
rule, rootless runsc under this unit's hardening on black, a git push through
Tailscale SSH into `git-shell`, the June environment endpoint call, and a
build's report to June dev.
