# Self-hosted E2B (E2B Embed, its single-node Docker Compose install) on black
# (demo; see client-data.nix): Firecracker sandboxes on black's real KVM.
#
# Embed is written for an Ubuntu host it may mutate: its orchestrator runs as
# a host process (nsenter into PID 1's namespaces) and its host-setup step
# writes /etc. On NixOS this module does that host part declaratively, and
# e2b/compose.black.yaml adapts the upstream compose file:
# - kernel modules (nbd, tun), hugepages and sysctls, the nbd udev rule;
# - upstream's host paths (/var/lib/e2b, /fc-*, /orchestrator) as bind mounts
#   from /var/lib/client-data/e2b/host, so all its data sits in one place;
# - /usr/local/bin with the tools the orchestrator execs from a fixed FHS
#   PATH (iptables, ip, rsync, mkfs.ext4, bash...), and nix-ld for the
#   orchestrator binary itself;
# - firewall: sandboxes may reach the orchestrator's redirect ports, the
#   Convex networks and the tailnet may reach the api (3000) and client-proxy
#   (3002), nothing else (plain HTTP; on the tailnet inside WireGuard);
# - a CPU/memory ceiling on /sys/fs/cgroup/e2b, where every Firecracker runs.
{stateDir}: {
  config,
  pkgs,
  lib,
  ...
}: let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  dataDir = "${stateDir}/e2b";
  secretsFile = "${stateDir}/secrets/e2b.env";
  # E2B Embed at e2b-dev/infra (also published as e2b-dev/runtime). The .env
  # pins every image and binary; bump both files together.
  rev = "78d5ff91515b58a9bd2d0b28b14f80428c63d15e";
  upstream = file: hash:
    pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/e2b-dev/infra/${rev}/embed/compose/${file}";
      name = "e2b-embed-${lib.removePrefix "." file}";
      inherit hash;
    };
  upstreamCompose = upstream "compose.yaml" "sha256-w/1JuaP0WcdwSoDm55uxD/SQkBM/uiG5xMUBYlueQek=";
  upstreamEnv = upstream ".env" "sha256-U3Rjwqug7Am/9HVJFx/3KXOj3KWdpHogp29r+sG0opg=";
  blackEnv = builtins.readFile ./e2b/black.env;
  envValue = name: builtins.head (builtins.match ".*\n${name}=([^\n]*)\n.*" "\n${blackEnv}\n");
  compose = lib.concatStringsSep " " [
    "${docker} compose --project-directory ${dataDir}"
    "-f ${upstreamCompose} -f ${./e2b/compose.black.yaml}"
    "--env-file ${upstreamEnv} --env-file ${./e2b/black.env} --env-file ${secretsFile}"
  ];
  hostDirs = ["/var/lib/e2b" "/fc-versions" "/fc-kernels" "/fc-busybox" "/fc-envd" "/fc-vm" "/orchestrator"];
  dirName = path: lib.removePrefix "-" (builtins.replaceStrings ["/"] ["-"] path);
  volumes = ["postgres" "redis" "clickhouse" "seed-state"];
  # What preflight checks for and the orchestrator and template builds exec.
  hostTools = pkgs.buildEnv {
    name = "e2b-host-tools";
    paths = with pkgs; [
      bashInteractive
      coreutils
      curl
      e2fsprogs
      findutils
      gawk
      glibc.bin
      gnugrep
      gnused
      iproute2
      config.networking.firewall.package
      kmod
      procps
      rsync
      config.systemd.package
      util-linux
    ];
  };
  # Ports the stack listens on in the host network namespace that the
  # tailnet must not reach (tailscale0 is trusted on black): client-proxy
  # health 3003, orchestrator 5007/5008 (an unauthenticated control API) and
  # 6061, api gRPC 5009/5109, pprof 6060. The api (3000) and client-proxy
  # (3002) stay open to it.
  hostPorts = "3001,3003,5007:5009,5109,6060,6061";
in {
  boot.kernelModules = ["nbd" "tun"];
  boot.extraModprobeConfig = "options nbd nbds_max=${envValue "NBDS_MAX"} max_part=16";
  boot.kernel.sysctl = {
    "vm.nr_hugepages" = lib.toInt (envValue "HUGEPAGES");
    "vm.max_map_count" = 1048576;
    "net.ipv4.tcp_max_syn_backlog" = 65535;
  };
  services.udev.extraRules = ''
    KERNEL=="nbd*", GROUP="disk", MODE="0660"
  '';
  programs.nix-ld.enable = true;

  fileSystems = lib.genAttrs hostDirs (path: {
    device = "${dataDir}/host/${dirName path}";
    fsType = "none";
    options = ["bind"];
  });

  systemd.tmpfiles.rules =
    [
      "d ${dataDir} 0700 root root -"
      "d ${dataDir}/host 0755 root root -"
      "d /usr/local 0755 root root -"
      "L+ /usr/local/bin - - - - ${hostTools}/bin"
    ]
    ++ map (path: "d ${dataDir}/host/${dirName path} 0755 root root -") hostDirs;

  networking.firewall = {
    # The orchestrator REDIRECTs sandbox traffic (hyperloop, NFS, portmapper,
    # the egress TCP firewall) to its ports 5010-5018 here. Its host-side
    # sandbox interfaces are veth-<slot>.
    extraCommands = ''
      ip46tables -I nixos-fw -i veth-+ -p tcp -m multiport --dports 5010:5018 -j nixos-fw-accept
      ip46tables -I nixos-fw -i tailscale0 -p tcp -m multiport --dports ${hostPorts} -j nixos-fw-refuse
      # Convex actions call the api and client-proxy through host-gateway;
      # every Convex deployment's network is a bridge named cvx-<name>.
      ip46tables -I nixos-fw -i cvx-+ -p tcp -m multiport --dports 3000,3002 -j nixos-fw-accept
    '';
  };

  systemd.services = {
    e2b-secrets = {
      description = "Generate the E2B team API key and api secrets once";
      unitConfig.ConditionPathExists = "!${secretsFile}";
      path = [pkgs.openssl];
      serviceConfig.Type = "oneshot";
      script = ''
        umask 077
        {
          echo "TEAM_API_KEY=e2b_$(openssl rand -hex 20)"
          echo "ADMIN_TOKEN=$(openssl rand -hex 32)"
          echo "SANDBOX_ACCESS_TOKEN_HASH_SEED=$(openssl rand -hex 32)"
        } > ${secretsFile}.tmp
        mv ${secretsFile}.tmp ${secretsFile}
      '';
    };

    # Every sandbox's Firecracker lives in /sys/fs/cgroup/e2b/<sandbox>,
    # outside Docker's and systemd's cgroups. Guest memory comes from the
    # hugepage pool (HUGEPAGES); this caps the rest, with the same low CPU
    # weight as client-data.slice.
    e2b-sandbox-limits = {
      description = "CPU and memory ceiling for E2B sandboxes";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /sys/fs/cgroup/e2b
        echo "200000 100000" > /sys/fs/cgroup/e2b/cpu.max   # 2 CPUs
        echo 20 > /sys/fs/cgroup/e2b/cpu.weight
        echo 512M > /sys/fs/cgroup/e2b/memory.max
        echo 0 > /sys/fs/cgroup/e2b/memory.swap.max
      '';
    };

    e2b = {
      description = "Self-hosted E2B Embed (demo, no client data)";
      wantedBy = ["multi-user.target"];
      after = ["docker.service" "e2b-secrets.service" "e2b-sandbox-limits.service" "systemd-sysctl.service"];
      requires = ["docker.service"];
      # Wants, not Requires: a switch that changes the limits restarts that
      # oneshot, and Requires would stop every sandbox with it.
      wants = ["e2b-secrets.service" "e2b-sandbox-limits.service"];
      unitConfig.RequiresMountsFor = hostDirs;
      reloadIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # The first start pulls ~4 GB of images and builds the base template.
        TimeoutStartSec = "45min";
        # Volume directories: created here, not by tmpfiles, which would
        # reset the owners the database containers give them.
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${lib.concatMapStringsSep " " (v: "${dataDir}/${v}") volumes}";
        ExecStart = "${compose} up -d --wait --remove-orphans";
        ExecReload = "${compose} up -d --wait --remove-orphans";
        # Ends every running sandbox; data and templates stay.
        ExecStop = "${compose} down";
        TimeoutStopSec = "3min";
      };
    };
  };
}
