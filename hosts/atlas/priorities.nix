# Keep t3code, Hermes and the ways in (sshd, Tailscale) responsive when the
# agents saturate atlas.
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
  # Batch work: atlas-containers.slice once docker.nix lands (PR #25). The
  # ceiling keeps ~34G for t3code, its agents, their checks and the system.
  # It also held the self-hosted CI runners (atlas-ci.slice) until Linux CI
  # moved to Ubicloud on 2026-10-26. MemorySwapMax because zram's compressed pages are
  # not charged to the cgroup, so unlimited swap would let a capped slice
  # spill into host RAM anyway.
  systemd.slices.atlas = {
    description = "Docker containers and other batch work";
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      # 14/16G since 2026-10-26: at 24/28G, CI next to ~40 agent sessions and
      # the agent checks left atlas without memory (unreachable, hard reset).
      # CI has since left atlas; the cap stays for the containers.
      MemoryHigh = "14G";
      MemoryMax = "16G";
      MemorySwapMax = "4G";
    };
  };

  # Loaded before any service starts, so systemd can set io.bfq.weight on
  # their cgroups. Writing "bfq" to a scheduler file would also autoload it.
  boot.kernelModules = ["bfq"];

  # Weights only compete between siblings (runbooks/atlas-build-sweep.md has
  # the full table). Default is 100. Inside system.slice the units below get
  # 1000. Next to system.slice, atlas.slice (Docker containers)
  # gets 20. systemd maps IOWeight onto BFQ's 1-1000 range: 1000 becomes an
  # io.bfq.weight of 181, 20 stays 20.
  # t3code's cgroup also holds every agent session it spawns, so this favours
  # the agents together with the server, over containers and background jobs.
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
