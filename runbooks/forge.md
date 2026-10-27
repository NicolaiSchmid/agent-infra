# Forge operations

`forge` is the Apple-silicon build host. It runs T3 Code and macOS GitHub
Actions runners natively. Linux CI no longer runs here: since 2026-10-26 Linux
jobs for `NicolaiSchmid/*` and `apex-cc` run on Ubicloud managed runners
(`runs-on: ubicloud-standard-N`). The `forge-linux` Lima VM that used to host
arm64 Linux runners is retired; see [Decommission the Linux VM](#decommission-the-linux-vm).

## Connect and deploy

Use the Tailnet address after initial enrollment:

```bash
ssh nschmid10049@forge
```

Deploy a checked-out configuration from `forge` (`~/agent-infra` is a plain
copy of this repository today; `rsync` the tree over or replace it with a git
clone before switching):

```bash
sudo darwin-rebuild switch --flake ~/agent-infra#forge
```

Verify the core services:

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3773
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
```

T3 Code is available inside the Tailnet at:

```text
https://forge.takaya-buri.ts.net/
```

Forge runs the T3 server from the nightly channel, pinned in
`hosts/forge/t3code-app/` (atlas stays on the stable pin in dotfiles-nix). To
bump it, set the version from `npm view t3 dist-tags` in `package.json`, run
`bun install` in that directory, check `bun install --frozen-lockfile`, then
switch and restart the daemon:

```bash
sudo launchctl kickstart -k system/org.nixos.t3code
```

Since the 0.1.1 nightlies the `t3` npm package is only a launcher with no
dependencies. On first start of a new version it downloads that version's
`darwin-arm64` executable from the GitHub release into
`~/.local/share/t3code/runtime/versions/<version>`, checks it against the
release's `SHA256SUMS`, and runs it. So the first start after a bump needs
network access and takes longer. Old version folders are left there; delete
them by hand.

Claude Code and Codex come from the same dotfiles-nix pins as the MacBook and
are on the daemon's PATH. Their logins live in the `nschmid10049` home and are
not managed here; after a fresh install run `claude` (then `/login`) and
`codex login` once as that user.

The Tailscale standalone app owns the persistent Serve configuration. If it is
ever reset, restore it from the logged-in macOS account:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --yes http://127.0.0.1:3773
```

## Xcode

The native runner uses `/Applications/Xcode.app`. After an Xcode update, run:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcrun --sdk iphoneos --show-sdk-version
```

Signing certificates and provisioning profiles belong in the runner account's
keychain and must not be committed to this repository.

The iOS 26.5 simulator runtime is installed. List available destinations with:

```bash
xcrun simctl list devices available
```

## Register the runners

GitHub binds each runner process to one repository or organization. Forge uses
separate installation directories and services when the same host serves more
than one scope. Repository runners currently use these names:

```text
forge-macos-june
forge-macos-fifthset
forge-macos-mietprofi
forge-macos-nunc-immo
forge-macos-wasc-io
forge-macos-mosaic            (repository renamed to vamoo)
forge-macos-nicolaischmid-de
forge-macos-ilovegrain
forge-macos-ilovegrain-2
forge-macos-zero-mobile
```

steno's runners (1 Linux + 4 macOS) were removed on 2026-10-27: steno is
public (hosted macOS is free) and forge now hosts the prometheus hub, whose
credentials any job on forge could read. Fork PRs on steno need approval for
all external contributors. History: steno had four macOS runners because its Swift CI runs two macOS jobs per
push and its agents open many pull requests at once; on 2026-09-28 ten runs
were queued behind two runners. Additional runners for a scope are plain
copies of an existing runner directory (`rsync -a --exclude _work --exclude
_diag --exclude '.runner' --exclude '.runner_migrated' --exclude '.credentials*'
--exclude .env --exclude .path --exclude .service`), registered under the
`-N` name with the same labels. A copied `.runner_migrated` makes `config.sh`
refuse with "already configured"; a new repository's runner is copied the
same way (forge-macos-ilovegrain was, 2026-10-12). Every macOS runner runs as `nschmid10049`; steno's workflow keeps
build products per runner under `~/Library/Caches/steno-ci/<runner name>/`.
Memory allows more: with two xcodebuilds running, the runner processes and
builds use about 1.3 GiB and swap stays empty. The host has 10 cores, so more
than four concurrent xcodebuilds would mostly contend for CPU.

Create registration tokens in the target GitHub repository or organization.
Tokens expire quickly, so generate them only when ready to run these commands.

Register a macOS runner:

```bash
cd ~/actions-runner-macos-SCOPE
./config.sh --url GITHUB_URL --token REGISTRATION_TOKEN \
  --name forge-macos-SCOPE --labels forge,macos,arm64,ios,xcode --unattended
./svc.sh install
./svc.sh start
```

### Runner selection from workflows

The macOS jobs in june, fifthset, mietprofi, steno and ilovegrain do not
hard-code labels. They read the `MACOS_RUNS_ON` repository variable, which the
`forge-runner-watchdog` timer on atlas (`hosts/atlas/forge-runner-watchdog.sh`)
keeps pointed at `["self-hosted","macOS","ARM64"]` while that repository's
Forge macOS runners are online, and at the hosted image the workflow uses as
its default otherwise (`macos-15`; `macos-26` for ilovegrain):

```yaml
runs-on: ${{ fromJSON(vars.MACOS_RUNS_ON || '"macos-15"') }}
```

`journalctl -u forge-runner-watchdog` on atlas shows every flip. Add a
repository to the `repos` table in the script when its workflows start reading
`MACOS_RUNS_ON`. ilovegrain's `IOS_RELEASE_RUNS_ON` (release pinned to the
`ios`-labelled runner) is set by hand and not managed by the watchdog.
zero-mobile and the wasc-io repositories hard-code Forge labels or carry their
own default.

Target the runners from a workflow with the labels GitHub assigned at
registration (matching is cumulative; all listed labels must be present):

```yaml
runs-on: [self-hosted, macOS, ARM64]   # native forge (Xcode, simulators)
```

Most scopes have one macOS runner, so macOS jobs inside one repository run
serially. Register another runner directory for a scope if that becomes a
bottleneck (see steno above).

Do not give untrusted pull requests access to the self-hosted runners. A job
on a macOS runner can access the host account and signing material.

## Unattended operation

- Sleep is disabled on AC (`pmset -g` shows `SleepDisabled 1`, `sleep 0`). On
  battery the default sleep timers still apply, so keep the machine plugged in.
- FileVault is on. After a power loss or reboot the machine waits at the
  pre-boot unlock screen and nothing (Tailscale, runners, T3 Code) starts until
  someone types the account password. Use `sudo fdesetup authrestart` for
  planned reboots so the volume unlocks once without a keyboard.
- Automatic macOS update installation is enabled in System Settings; combined
  with FileVault that means an unattended reboot can take every runner offline.
  Turn off "Install macOS updates" or expect to unlock the machine after
  updates.
- All macOS runner services are per-user LaunchAgents and the Tailscale app is
  a login item, so the `nschmid10049` GUI session must be logged in. After an
  authenticated restart (macOS update) the machine boots to the login window,
  and Tailscale and the macOS runners stay down until someone logs in. Log in via Screen Sharing on the LAN
  (`open vnc://forge.local`) to restore them; SSH works on the LAN meanwhile.
  `launchctl bootstrap gui/<uid>` fails from SSH without a GUI session.

## Logs

```bash
tail -f ~/Library/Logs/t3code.log
tail -f ~/Library/Logs/t3code.error.log
```

## Decommission the Linux VM

One-off checklist for retiring `forge-linux` (October 2026; Linux CI moved to
Ubicloud). The configuration no longer declares the VM, its launchd daemon,
`lima` or `qemu`, but nothing on the machine is removed automatically.

1. Check no Linux job still needs it: every workflow in the affected
   repositories uses `ubicloud-standard-N` or a hosted image, not
   `vars.LINUX_RUNS_ON` or `[self-hosted, Linux, ...]`.
2. Deploy the new configuration (as above). nix-darwin unloads the removed
   `org.nixos.forge-linux` daemon; check, and remove it by hand if it is still
   loaded:

   ```bash
   sudo launchctl print system/org.nixos.forge-linux >/dev/null 2>&1 &&
     sudo launchctl bootout system/org.nixos.forge-linux
   ```

3. Stop and delete the VM. `limactl` is no longer on the system PATH after the
   switch, so run it from nixpkgs (or do this step before the switch):

   ```bash
   nix run nixpkgs#lima -- stop forge-linux
   nix run nixpkgs#lima -- delete forge-linux
   nix run nixpkgs#lima -- prune          # download cache in ~/Library/Caches/lima
   ```

4. Deregister the Linux runners from GitHub (from any machine with `gh`
   authenticated as an admin of these scopes). They show as offline once the
   VM is gone:

   ```bash
   for repo in june fifthset mietprofi vamoo nicolaischmid.de steno ilovegrain; do
     gh api "repos/NicolaiSchmid/$repo/actions/runners?per_page=100" \
       --jq '.runners[] | select(.name | startswith("forge-linux-")) | .id' |
       while read -r id; do gh api -X DELETE "repos/NicolaiSchmid/$repo/actions/runners/$id"; done
   done
   for org in nunc-immo wasc-io; do
     gh api "orgs/$org/actions/runners?per_page=100" \
       --jq '.runners[] | select(.name | startswith("forge-linux-")) | .id' |
       while read -r id; do gh api -X DELETE "orgs/$org/actions/runners/$id"; done
   done
   ```

5. Free the disk: the VM held about 65 GiB in `~/.lima` (October 2026).
   `limactl delete` removes `~/.lima/forge-linux`; remove `~/.lima` entirely if
   `limactl list` shows no other instance, and the old logs:

   ```bash
   rm -f ~/Library/Logs/forge-linux.log ~/Library/Logs/forge-linux.error.log
   du -sh ~/.lima ~/Library/Caches/lima 2>/dev/null
   ```

   The weekly nix GC (Sunday 04:15) collects the old lima/qemu store paths.
