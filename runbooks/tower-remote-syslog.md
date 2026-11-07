# Tower remote syslog

Implemented and verified 2026-11-07. Receiver is Atlas, not Black or Forge.
Atlas is always on, has an independent persistent ext4 state disk, and is
reachable from Tower over host Tailscale. Black remains the hypervisor.
Tower's route to 100.122.138.66 uses tailscale1 with source 100.64.0.99;
this is the Unraid host plugin, not the separate tower-arr container.
The observed direct encrypted path crossed the home WAN to Black's public
endpoint; these machines do not share a LAN.

## Configuration

- Atlas imports `hosts/atlas/tower-syslog.nix`.
- Dedicated `tower-syslog.service`, automatic startup and restart on failure.
  Requires the persistent state mount; retries binding if Tailscale is late.
- TCP 5514 binds only 100.122.138.66. No public firewall opening. The receiver
  writes only messages whose peer address is Tower's 100.64.0.99.
- `/srv/agents-state/logs/tower/syslog.log`, root:root 0640, directory 0750.
  Each file write is synced to disk. This is on /dev/vdb1, not Tower storage.
- Dedicated hourly `tower-syslog-rotate.timer`: daily rotation, also above
  16 MiB at the next hourly check, 90 rotations, maxage 90 days, compression
  with delaycompress, HUP to reopen files. This is not a strict disk quota:
  a burst can exceed 16 MiB between checks, and busy periods shorten history.
  Age cleanup happens when rotation runs on a nonempty file.
- Tower source of truth: `hosts/tower/00-atlas-remote.conf`, installed at
  `/boot/config/rsyslog.d/00-atlas-remote.conf` and symlinked into
  `/etc/rsyslog.d/`. Unraid 7.2.4 `/etc/rc.d/rc.M` recreates these symlinks
  before starting rsyslog on boot. No go-script or GUI rsyslog.cfg required.
- Forwarding runs before the existing blocklist. TCP with RFC5424 timestamps,
  infinite reconnect retries, 4096-message RAM queue, no disk spool. Existing
  local /mnt/fast logging and all workloads were preserved. Flash contains
  configuration only; this adds no continuous USB log writes.

## Validation

Both rsyslog configurations validated. Built using the deployed Atlas baseline
(e4b8e80, fix/atlas-drop-checks-gate) with the existing flake.lock, without
upgrading inputs. Dry activation showed no workload restarts. Switched NixOS
system profile persistently; t3code, hermes and hermes-serve stayed active.
Tower's rsyslog alone was restarted to load forwarding; Tower was not rebooted.

Verified real Tower logger markers and ordinary sshd/rsyslog messages on Atlas,
an established TCP connection from 100.64.0.99, and both units enabled.
Stopped only the receiver briefly: two messages sent during the interruption
arrived after receiver startup, and previous records survived. Forced rotation
twice verified reopen, retained records, and readable .2.gz compression. A
message sent from another tailnet host was discarded. Disk mount and file
permissions checked. No reboot or crash testing was performed; startup is
verified by configuration and enabled units, not a reboot test. Both machines'
UTC clocks matched; Tower's source timestamps currently carry -08:00.

## Operations

```sh
ssh atlas 'sudo tail -100 /srv/agents-state/logs/tower/syslog.log'
ssh atlas 'sudo zgrep -h "pattern" /srv/agents-state/logs/tower/syslog.log*.gz'
ssh atlas 'systemctl status tower-syslog tower-syslog-rotate.timer'
ssh tower 'logger -t tower-remote-syslog "manual verification"'
```

The implementation is on `feat/tower-remote-syslog`, based on the deployed
Atlas branch, rather than rebuilding from newer unrelated main changes.
Retain the module import when integrating later infrastructure changes.

## Limits

This preserves messages already received independently of Tower's disks and
boot stick. A hard kernel freeze, NIC failure, WAN/Tailscale outage, or abrupt
power loss can prevent final messages from leaving Tower. TCP is not an
application-level durable acknowledgement protocol; in-flight messages can
still be lost or duplicated. The RAM queue survives brief receiver outages,
not Tower reboots/freezes, and drops new messages once full to avoid blocking
local logging. It is not a root-cause fix, kernel crash dump, netconsole, or
capture of every container/application log. Atlas/Black downtime also interrupts
reception. No decision about permanently separating other services is implied.
