# Keep t3code, Hermes and the ways in (sshd, Tailscale) responsive when the
# agents and CI saturate atlas.
#
# atlas's virtio disks default to the "none" scheduler, which ignores I/O
# priorities and IOWeight entirely. On 2026-10-04 the t3code server sat in D
# state behind agent builds (io pressure 68 %, 4-10 s per request). BFQ makes
# the weights below and IOSchedulingClass=idle actually apply.
{
  lib,
  pkgs,
  ...
}: let
  interactive = [
    "t3code"
    "hermes"
    "nginx"
    "sshd"
    "tailscaled"
    "tailscaled-t3code"
    "tailscale-t3code-serve"
  ];
  setScheduler = name:
    pkgs.writeShellScript "atlas-io-scheduler-${name}" ''
      for q in /sys/block/vd[a-z]/queue/scheduler; do echo ${name} >"$q"; done
    '';
in {
  # Loaded before any service starts, so systemd can set io.bfq.weight on
  # their cgroups. Writing "bfq" to a scheduler file would also autoload it.
  boot.kernelModules = ["bfq"];

  # Default weight is 100. The CI runners' slice gets 20 (github-runners.nix).
  # systemd maps IOWeight onto BFQ's 1-1000 range: 1000 becomes an
  # io.bfq.weight of 181, 20 stays 20.
  # t3code's cgroup also holds every agent session it spawns, so this favours
  # the agents together with the server, over CI and background jobs.
  systemd.services =
    lib.genAttrs interactive (_: {
      serviceConfig = {
        CPUWeight = 1000;
        IOWeight = 1000;
      };
    })
    // {
      # A unit rather than a udev rule: a switch starts it (udev rules only
      # apply to new events, so vda/vdb would stay on "none" until reboot),
      # and rolling back to a generation without it stops it, which restores
      # "none".
      atlas-io-scheduler = {
        description = "BFQ I/O scheduler on the virtio disks";
        wantedBy = ["sysinit.target"];
        after = ["systemd-modules-load.service"];
        before = map (u: "${u}.service") interactive;
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = setScheduler "bfq";
          ExecStop = setScheduler "none";
        };
      };
    };
}
