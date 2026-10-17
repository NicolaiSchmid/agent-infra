# Keep t3code, Hermes and the ways in (sshd, Tailscale) responsive when the
# agents and CI saturate atlas.
#
# atlas's virtio disks default to the "none" scheduler, which ignores I/O
# priorities and IOWeight entirely. On 2026-10-04 the t3code server sat in D
# state behind agent builds (io pressure 68 %, 4-10 s per request). BFQ makes
# the weights below and IOSchedulingClass=idle actually apply.
{lib, ...}: let
  interactive = [
    "t3code"
    "hermes"
    "nginx"
    "sshd"
    "tailscaled"
    "tailscaled-t3code"
    "tailscale-t3code-serve"
  ];
in {
  boot.kernelModules = ["bfq"];
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="vd[a-z]", ATTR{queue/scheduler}="bfq"
  '';

  # Default weight is 100. The CI runners get 20 (github-runners.nix).
  # t3code's cgroup also holds every agent session it spawns, so this favours
  # the agents together with the server, over CI and background jobs.
  systemd.services = lib.genAttrs interactive (_: {
    serviceConfig = {
      CPUWeight = 1000;
      IOWeight = 1000;
    };
  });
}
