# Forge operations

`forge` is the Apple-silicon build host. It runs T3 Code and macOS GitHub
Actions runners natively. `forge-linux`, a Lima VM, provides isolated arm64
Ubuntu runners with Docker.

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
limactl list forge-linux
```

T3 Code is available inside the Tailnet at:

```text
https://forge.takaya-buri.ts.net/
```

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
forge-macos-june       forge-linux-june
forge-macos-fifthset   forge-linux-fifthset
forge-macos-mietprofi  forge-linux-mietprofi
forge-macos-nunc-immo  forge-linux-nunc-immo
forge-macos-wasc-io    forge-linux-wasc-io
forge-macos-mosaic     forge-linux-mosaic
forge-macos-nicolaischmid-de  forge-linux-nicolaischmid-de
forge-macos-steno      forge-linux-steno
```

Create registration tokens in the target GitHub repository or organization.
Tokens expire quickly, so generate them only when ready to run these commands.

Register macOS:

```bash
cd ~/actions-runner-macos-SCOPE
./config.sh --url GITHUB_URL --token REGISTRATION_TOKEN \
  --name forge-macos-SCOPE --labels forge,macos,arm64,ios,xcode --unattended
./svc.sh install
./svc.sh start
```

Register Linux:

```bash
limactl shell forge-linux
cd /opt/actions-runner-SCOPE
./config.sh --url GITHUB_URL --token REGISTRATION_TOKEN \
  --name forge-linux-SCOPE --labels forge,linux,arm64,docker --unattended
mkdir -p home && echo "HOME=$PWD/home" >> .env   # private HOME per runner
cat >> .env <<'EOF'
ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/forge-hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/forge-hooks/job-completed.sh
EOF
sudo ./svc.sh install
unit=$(systemctl list-unit-files --no-legend 'actions.runner.*SCOPE*.service' | awk '{print $1}')
sudo mkdir -p /etc/systemd/system/$unit.d
printf '[Service]\nRestart=always\nRestartSec=10\nKillMode=control-group\n' | sudo tee /etc/systemd/system/$unit.d/restart.conf
sudo systemctl daemon-reload
sudo ./svc.sh start
```

The `Restart=always` drop-in matters: `svc.sh` installs units without a restart
policy, and a job that gets OOM-killed by the kernel (mosaic E2E peaked at
10 GiB) leaves the unit `failed` and the runner offline until someone restarts
it. All eight Linux units carry the drop-in as of 2026-09-25.

Every Linux runner runs as the same VM user. Without the per-runner `HOME`
in `.env`, concurrent jobs race in `~/setup-pnpm` and the pnpm store
(`ENOTEMPTY`, `ERR_PNPM_ENOENT`). The VM has 6 CPUs and 16 GiB (the host
keeps 8 GiB for macOS and Xcode); a Next.js production build alone needs more
than 2 GiB of Node heap. Resize a running instance with
`limactl stop forge-linux && limactl edit forge-linux --cpus 6 --memory 16 && limactl start forge-linux`.

### Heavy-job serialization

Eight repositories share the VM, and one E2E run (Next.js server plus
Chromium) peaked at 10 GiB, so heavy jobs are serialized across runners with
a shared lock implemented as runner hooks in `/opt/forge-hooks/`:
`job-started.sh` blocks until it can `mkdir /var/lock/forge-heavy` when
`"owner/repo job_id"` matches a regex in `heavy-jobs.txt`; `job-completed.sh`
releases it. The lock records its holder's `Runner.Worker` PID; a lock whose
holder is gone (job cancelled or killed before the completed hook ran) or older
than two hours is treated as stale, and a waiter whose own job was cancelled
exits instead of lingering. The wait shows
up in the job's "Set up runner" step and counts against `timeout-minutes`.
Edit `heavy-jobs.txt` on the VM (and here) to add jobs; no restart needed.
Runner units also carry `Restart=always` so an OOM-killed job cannot leave a
runner offline.

### Runner selection from workflows

Workflows in june, fifthset, mietprofi and mosaic do not hard-code labels. They read
repository variables that the `forge-runner-watchdog` timer on atlas
(`hosts/atlas/forge-runner-watchdog.nix`) keeps pointed at Forge while its
runners are online, and at GitHub-hosted runners otherwise:

```yaml
runs-on: ${{ fromJSON(vars.LINUX_RUNS_ON || '"ubuntu-latest"') }}
runs-on: ${{ fromJSON(vars.MACOS_RUNS_ON || '"macos-15"') }}
```

`journalctl -u forge-runner-watchdog` on atlas shows every flip.

Target the runners from a workflow with the labels GitHub assigned at
registration (matching is cumulative; all listed labels must be present):

```yaml
runs-on: [self-hosted, Linux, ARM64]   # forge-linux VM (Ubuntu 24.04 arm64, Docker)
runs-on: [self-hosted, macOS, ARM64]   # native forge (Xcode, simulators)
```

Each scope has exactly one Linux and one macOS runner, so jobs inside one
repository run serially per platform. Register a second runner directory for a
scope if that becomes a bottleneck.

The Linux VM is arm64. `qemu-user-static` registers a binfmt handler so
x86_64-only Linux binaries shipped in npm packages still run (slower);
`hermes-compiler`'s `hermesc`, used by `expo export`, is the known case.
Rosetta would be faster but needs `softwareupdate --install-rosetta` (root) on
the host plus `rosetta: {enabled: true, binfmt: true}` in the Lima config.

The Linux VM ships `git`, `jq`, `curl`, `python3`/`pip3`, Docker, Node 24 LTS
with `npm`/`npx`, `yarn` 1.x and `pnpm` (installed with `npm -g`, not corepack shims, which refuse to run in a project that pins another `packageManager`), `gh`, and
`build-essential`. Pinned toolchain versions still come from `actions/setup-*`
steps, which support arm64 Linux; the system Node exists so that actions which
shell out to `yarn` or `npm` without a setup step (e.g.
`expo/expo-github-action`) find them, as they do on the hosted image. Jobs that rely on
the GitHub-hosted image's preinstalled tooling (`JAVA_HOME_17_X64`,
`ANDROID_HOME`, x64-only binaries) stay on `ubuntu-latest`; the fifthset Android
build is the current example.

Do not give untrusted pull requests access to either self-hosted runner. A job
on the macOS runner can access the host account and signing material; a job in
the Linux VM can control Docker inside that VM.

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
  authenticated restart (macOS update) the machine boots to the login window:
  the Lima VM and its Linux runners come back (system daemon) but Tailscale and
  the macOS runners do not. Log in via Screen Sharing on the LAN
  (`open vnc://forge.local`) to restore them; SSH works on the LAN meanwhile.
  `launchctl bootstrap gui/<uid>` fails from SSH without a GUI session.

## Logs

```bash
tail -f ~/Library/Logs/t3code.log
tail -f ~/Library/Logs/t3code.error.log
tail -f ~/Library/Logs/forge-linux.log
tail -f ~/Library/Logs/forge-linux.error.log
```
