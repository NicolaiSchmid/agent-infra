# agent-infra

NixOS infrastructure for a portable, beefy agent workstation.

This repo defines the machines that run Nicolai's long-lived AI coding setup:
T3 Code, Codex, Claude, Hermes, GitHub auth/cache state, and the working
directories those agents operate in.

## Shape

```text
black   Hetzner bare-metal host
  └─ atlas   NixOS VM for agent workloads
       ├─ t3code
       ├─ hermes
       ├─ codex / claude
       └─ /srv/agents-state
```

`black` is intentionally boring: RAID/NixOS, SSH, Tailscale, libvirt, and UDP
forwarding into the VM.

`atlas` is where the work happens. It imports the shared agent environment from
`dotfiles-nix`, owns the persisted state volume, and runs the agent services.
The VM layer keeps the setup cloneable and movable without tying the workstation
directly to one provider or physical install.

### Naming

- **Black** is the physical host.
- **Atlas** is the only agent VM and runs all agent workloads.
- **Domovoi** is the logical name of the Hermes assistant. It is not a separate
  VM or server: the `hermes` Docker container runs inside Atlas.
- Historical Tailscale devices named `domovoi` and `t3code` belong to the
  retired `one`/Domovoi environment. Current administration goes through
  `black`, `atlas`, and the dedicated `atlas-t3code` UI node.

## What Lives Here

- `hosts/black/` - bare-metal host, disks, libvirt, Atlas VM definition, network forwarding
- `hosts/atlas/` - agent VM, state mounts, Tailscale nodes, T3/Hermes overrides
- `modules/keys.nix` - public SSH keys
- `secrets/` - SOPS notes and encrypted runtime secrets
- `runbooks/` - bootstrap and migration procedures

The repo is public by design. Secrets and mutable runtime data stay out of Git.

## State Model

Durable agent state lives under:

```text
/srv/agents-state
```

Important subtrees include:

- `nicolai/` - user home, CLI auth, caches, shell config
- `t3code/` - T3 Code base dir
- `workspace/` - checked-out working repos and agent worktrees
- `hermes/data/` - Hermes runtime data
- `secrets/` - local secret material mounted into services

Hermes is built from `NousResearch/hermes-agent` by `hermes-image.service` and
runs as one `hermes-agent:latest` container under `hermes.service`. That
container runs both the gateway and dashboard. Its shell backend connects to
Atlas as `nicolai` over loopback SSH, so commands use Atlas's Nix-managed
toolchain and workspace rather than the container filesystem.

The dashboard listens on port `9119` inside Atlas. `hermes-serve.service` owns
its intended Tailscale Serve route, but Serve configuration is mutable; confirm
the live route with `ssh atlas 'tailscale serve status'` instead of assuming an
old `domovoi` hostname still points to it.

Atlas also includes a small `gh` wrapper for T3 Code that collapses repeated
`gh pr list --head ...` polling into a per-repo REST cache. This keeps T3's PR
status checks from burning GitHub GraphQL quota.

## Common Commands

Validate the flake:

```bash
nix flake check --no-build
```

Install `black` from Hetzner rescue:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#black \
  root@65.109.71.108
```

Build/install initial Atlas VM images on `black`:

```bash
nix run github:NicolaiSchmid/agent-infra#install-atlas -- \
  --replace-root \
  --replace-state \
  --start
```

Rebuild `black`:

```bash
nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra#black
```

Rebuild `atlas`:

```bash
nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra#atlas --target-host root@atlas
```

## Operational Rule

Do not casually restart `t3code`, Hermes, Codex, Claude, or their subprocesses.
They may be carrying active work. Config changes that affect service
environment, PATH, or runtime mounts should be applied in a planned window.

For a quick topology and health check:

```bash
ssh root@black 'virsh list --all'
ssh atlas 'systemctl is-active t3code hermes hermes-serve'
ssh atlas 'docker ps --filter name=hermes'
```

## Runbooks

- [Bootstrap](runbooks/bootstrap.md)
- [Historical: one/domovoi to black/atlas migration](runbooks/one-to-black-migration.md)
- [Secrets](secrets/README.md)
