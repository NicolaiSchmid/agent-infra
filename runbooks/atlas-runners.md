# Atlas Linux runners

Persistent x86_64 GitHub Actions runners for Nicolai's repositories run on
`atlas` as NixOS `services.github-runners` units, two per repository
(`hosts/atlas/github-runners.nix`, `runnersPerRepo`). They are the primary
Linux runners; the Forge arm64 VM is the fallback (and, for arch-neutral
repositories, the overflow), GitHub-hosted runners the last resort. The
`forge-runner-watchdog` timer on atlas keeps each repository's `LINUX_RUNS_ON`
variable pointed at the best available tier.

```text
atlas-linux-june        atlas-linux-fifthset    atlas-linux-mietprofi
atlas-linux-mosaic      atlas-linux-steno       atlas-linux-nicolaischmid-de
plus one -2 sibling of each (atlas-linux-june-2, ...)
labels: self-hosted, Linux, X64, atlas
```

Two per repository because one was a queue: mietprofi's sub-minute gate jobs
waited 6 to 10 minutes and mosaic's 13 to 51 minutes behind a single 13-minute
`quality` job (2026-09-28). The second runner is a full sibling (own user
`ghr-<repo>-2`, own directories under `<repo>-2/`). Raise `runnersPerRepo`
for more; every runner idles at about 100 MiB.

Atlas is CPU-bound (load 17 on 12 vCPUs, mostly the agents in t3code plus one
CI job), so runner units carry `CPUWeight=50`: under contention CI gets half
the share of a default unit and the agents stay responsive. Memory limits are
`MemoryHigh=8G` / `MemoryMax=11G` per runner; the largest job seen (mosaic
`quality`) peaks near 10 GiB, so it still fits while a second job runs beside
it.

## Isolation

Docker is not an isolation boundary, so the runners get none: no Docker socket,
no docker group. Each runner is its own static system user (`ghr-<repo>`,
group `github-runners`) inside the module's systemd sandbox
(`ProtectSystem=strict`, `PrivateUsers`, `ProtectHome`, `NoNewPrivileges`, syscall
filter). A job can write only its work dir and tool cache under
`/srv/agents-state/github-runners/<repo>/` and cannot read t3code, Hermes or
the agents' credentials in `/srv/agents-state/nicolai`. `MemoryMax=11G` and
`CPUWeight=50` per runner keep a runaway job from starving t3code and Hermes. The repositories
are private and only Nicolai's code runs here; this is protection against
mistakes, not against a hostile pull request. Jobs that need Docker stay on the
Forge VM (`forge-linux-*` runners, label `docker`).

## Registration

`/srv/agents-state/secrets/github-runner.token` (root, 0600) holds a GitHub
access token with `repo` scope. The runner passes it as `--pat` and mints its
own registration token, so label or work-dir changes re-register without manual
steps (a bare registration token would expire after an hour). Changing the
token file's content also re-registers. Organization runners (nunc-immo,
wasc-io) would need `admin:org` and are not configured here.

## Operations

```bash
systemctl list-units 'github-runner-*'
journalctl -u github-runner-june -n 50
systemctl restart github-runner-june          # wipes its work dir, keeps toolcache
```

Deploy like any atlas change: push to `main`, then on atlas
`nixos-rebuild switch --flake 'github:NicolaiSchmid/agent-infra/<sha>#atlas'`.
Runner units are independent of t3code and Hermes; a switch that only touches
them does not restart the agents. Prebuilt npm binaries run through nix-ld; the
units receive `NIX_LD`/`NIX_LD_LIBRARY_PATH` explicitly because the sandbox does
not inherit `/etc/profile`. actions/setup-* downloads persist in
`<repo>/toolcache` across restarts.
