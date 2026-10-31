# Client-data stack DEMO on black: self-hosted Convex deployments (convex.nix)
# with Garage S3 (garage.nix), E2B sandboxes (e2b.nix) and Traefik in front
# (traefik.nix), for moving June off Convex Cloud and Vercel Sandbox, and
# routes-api (routes.nix), through which each project pushes its own routes.
# It must not hold real client data; before tax-firm contracts it moves to its
# own server (runbooks/black-client-data-demo.md has the why and the move).
#
# black's job is running the atlas VM, which holds 52 GiB of black's 62 and 12
# of its 16 threads, so everything here sits in client-data.slice with a hard
# ceiling far below what is left:
# - every container (Docker's cgroup-parent), CPU/IO weight 20 next to
#   atlas's qemu at 100, and a quota of 3 CPUs;
# - E2B's sandboxes run outside Docker's cgroups and have their own ceiling
#   (e2b.nix), plus the hugepage pool for their guest memory.
# Containers carry oom_score_adj 1000, so a black-wide OOM takes them, never
# qemu.
#
# State: data, secrets and certificates under one directory,
# /var/lib/client-data, so the move is this config plus that directory.
let
  stateDir = "/var/lib/client-data";
  # Traefik's file provider directory: static files from the repository and
  # the routes each project pushes (traefik.nix, routes.nix).
  traefikDynamicDir = "${stateDir}/traefik-dynamic";
in {
  imports = [
    (import ./convex.nix {inherit stateDir;})
    (import ./e2b.nix {inherit stateDir;})
    (import ./traefik.nix {inherit stateDir traefikDynamicDir;})
    (import ./garage.nix {inherit stateDir;})
    (import ./routes.nix {inherit stateDir traefikDynamicDir;})
  ];

  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      cgroup-parent = "client-data.slice";
      # Docker sets the FORWARD policy to DROP when it enables forwarding;
      # black forwards atlas's NAT traffic and its Tailscale ports
      # (libvirt.nix), which must never depend on that.
      ip-forward-no-drop = true;
      log-driver = "json-file";
      log-opts = {
        max-size = "20m";
        max-file = "5";
      };
    };
  };

  systemd.slices.client-data = {
    description = "Client-data demo: Convex and E2B containers";
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 20;
      CPUQuota = "300%";
      MemoryHigh = "2750M";
      MemoryMax = "3G";
      MemorySwapMax = "1G";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0711 root root -"
    "d ${stateDir}/secrets 0700 root root -"
  ];
}
