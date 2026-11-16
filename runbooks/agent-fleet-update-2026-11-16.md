# Agent fleet update — 2026-11-16

Prepared releases: Codex CLI **0.169.0** (including code-mode host), Claude Code
**2.1.325**, T3 stable **0.1.9**, T3 nightly
**0.1.10-nightly.20261116.4787**. MacBook keeps both desktop channels; Forge
keeps nightly; Atlas moves to nightly; Black uses stable. Codex Desktop is a separate package
and is not changed by this CLI update.

Run these steps from the Mac, after both update PRs are merged and their final
commits pass CI. Nothing in this preparation activates a machine. A full
switch also applies the other configuration already merged into `main`.

## Prepare the local checkout and immutable rollout references

Use the existing checkout paths, adjusting these two variables if necessary.
Review local changes before updating; do not discard them.

```bash
export AGENT_INFRA="$HOME/git/personal/agent-infra"
export DOTFILES="$HOME/git/personal/dotfiles-nix"
git -C "$AGENT_INFRA" status --short
git -C "$DOTFILES" status --short
git -C "$AGENT_INFRA" switch main
git -C "$AGENT_INFRA" pull --ff-only
git -C "$DOTFILES" switch main
git -C "$DOTFILES" pull --ff-only
export INFRA_REV="$(git -C "$AGENT_INFRA" rev-parse HEAD)"
export INFRA_FLAKE="github:NicolaiSchmid/agent-infra/$INFRA_REV"
```

Keep this terminal open so the remote build and switch commands use the same
reviewed revision. macOS sudo may ask for a password. Remote SSH identities
must already work; Forge uses `nschmid10049`, Atlas and Black use `root`.

## Build first, without activation

These are builds on the respective machines, not test suites on Atlas.
Do not continue to switches if a build fails.

```bash
nix build "$DOTFILES/darwin#darwinConfigurations.nicolais-MacBook-Pro.system" --no-link
ssh nschmid10049@forge "nix build '$INFRA_FLAKE#darwinConfigurations.forge.system' --no-link"
ssh root@black "nix build '$INFRA_FLAKE#nixosConfigurations.black.config.system.build.toplevel' --no-link"
ssh root@atlas "nix build '$INFRA_FLAKE#nixosConfigurations.atlas.config.system.build.toplevel' --no-link"
```

## Switch from the Mac

Finish critical agent operations first. Thread recovery is best effort: shell
commands and native subagents can be cancelled. The Mac desktop and Forge job
can restart during their update; Atlas and Black defer T3 restart explicitly.

```bash
sudo darwin-rebuild switch --flake "$DOTFILES/darwin#nicolais-MacBook-Pro"
ssh -t nschmid10049@forge "sudo /run/current-system/sw/bin/darwin-rebuild switch --flake '$INFRA_FLAKE#forge'"
ssh root@black "nixos-rebuild switch --flake '$INFRA_FLAKE#black'"
ssh root@atlas "nixos-rebuild switch --flake '$INFRA_FLAKE#atlas'"
```

Black's full switch includes the operations T3 service and the current
declarative Convex settings. Existing manual Convex overrides are reconciled
by the configuration already on `main`. Its persistent Atlas VM definition
also records the 47 GiB boot allocation; this does not require rebooting Atlas.
The temporary `sip-spike` container and native phone service need their own
call-aware handoff; this sweep does not stop that container.

Then perform the explicit server restarts from this Mac terminal, with Atlas
last. Keep an SSH terminal to Atlas open to inspect startup if the UI drops.

```bash
ssh -t nschmid10049@forge 'sudo launchctl kickstart -k system/org.nixos.t3code'
ssh root@black 'systemctl restart t3code'
ssh root@atlas 'systemctl restart t3code'
```

On the Mac, quit and reopen the T3 desktop channel you use once the server
rollout is verified. The updated app links are `~/Applications/T3 Code.app`
and `~/Applications/T3 Code Nightly.app`. Check that automatic continuation
is enabled in T3 settings; project-specific overrides can opt out.

## Verify the running processes

```bash
codex --version
claude --version
ssh nschmid10049@forge '/run/current-system/sw/bin/codex --version; /run/current-system/sw/bin/claude --version'
ssh root@black '/run/current-system/sw/bin/codex --version; /run/current-system/sw/bin/claude --version; systemctl is-active t3code'
ssh root@atlas '/run/current-system/sw/bin/codex --version; /run/current-system/sw/bin/claude --version; systemctl is-active t3code'
```

Expect Codex 0.169.0 and Claude Code 2.1.325. Check actual server versions and
update capability separately from the installed bootstrap pin:

```bash
ssh nschmid10049@forge "curl -fsS http://127.0.0.1:3773/.well-known/t3/environment | /run/current-system/sw/bin/jq '{serverVersion, selfUpdate: .capabilities.serverSelfUpdate}'"
ssh root@black "curl -fsS http://127.0.0.1:3773/.well-known/t3/environment | jq '{serverVersion, selfUpdate: .capabilities.serverSelfUpdate}'"
ssh root@atlas "curl -fsS http://127.0.0.1:3773/.well-known/t3/environment | jq '{serverVersion, selfUpdate: .capabilities.serverSelfUpdate}'"
```

Expect `boot-service` on all three, stable 0.1.9 on Black and the pinned
nightly on Forge and Atlas. If a home already has a launcher-selected newer version,
startup preserves it. If it has an older selected version, use the in-app
updater to select the prepared release; do not delete the service-state file.
Confirm an eligible interrupted thread resumes after reconnecting. Do not
use an irreversible command as a recovery test.

## Recovery and rollback boundary

If startup fails, inspect `journalctl -u t3code -n 100` on Linux and
`~/Library/Logs/t3code.error.log` on Forge. Leave the service stopped before
restoring database files. The initial adoption backup is under:

- Atlas: `/srv/agents-state/t3code/runtime/pre-launcher-backup.*`
- Black: `/var/lib/t3code/runtime/pre-launcher-backup.*`
- Forge: `~/.local/share/t3code/runtime/pre-launcher-backup.*`

Subsequent in-app updates use T3's own preflight, database backup and trial
rollback. A Nix generation rollback changes the launcher and provider tools,
but does not undo the updater-owned child version or database migration.
Restore the matching SQLite database, WAL/SHM files and settings together;
never just point an old executable at a newer migrated database.

## Consolidated configuration

This sweep records Atlas's live check limits (20/24/4 GiB for high/max/swap)
and Hermes's 1 GiB memory protection. T3's 14 GiB protection and the container
slice's 14/16 GiB limits were already declared. Black's previous June runtime,
capacity and retired-deployment overrides have already been replaced by the
current `main` configuration; no old override files are copied back in.

Unmerged prototype work (Prometheus UI/recorder, ingress experiments and the
separate Docker placement work) is not silently included in this release
sweep. Older Atlas-only launcher PR #72 is superseded by the shared launcher
implementation here. The existing check-gate removal is retained.
