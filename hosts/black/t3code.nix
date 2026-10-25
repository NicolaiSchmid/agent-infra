# A small T3 Code instance on black itself, for operating the host when atlas
# is the problem (memory thrash, load, disk fills, paused VM). Same pinned t3
# release as atlas, but sized to stay out of atlas's way: black has ~7G of RAM
# left next to the 52G VM.
#
# State lives in a preallocated ext4 image instead of on black's btrfs root:
# that root is what fills up during atlas incidents, and SQLite needs to keep
# writing exactly then. The image is NOCOW + fallocated, so its blocks are
# already allocated when btrfs runs out.
#
# Reachable at https://black.<tailnet> (Serve on black's own node, through
# the same CORS shim as atlas) and via T3 Connect once linked (runbook).
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  keys = import ../../modules/keys.nix;
  image = "/var/lib/t3code-state.img";
  imageSize = "5G";
  stateDir = "/var/lib/t3code";
  appDir = "${stateDir}/app";
  homeDir = "${stateDir}/home";
  workspace = "${stateDir}/workspace";
  tmpDir = "${stateDir}/tmp";
  # Same pin as atlas so both hosts run one t3 release.
  manifest = "${inputs.dotfiles-src}/darwin/agents/t3code-app";

  # Tools an agent needs to diagnose black and the atlas VM.
  opsTools = with pkgs; [
    btrfs-progs
    compsize
    e2fsprogs
    iotop
    libvirt
    lsof
    procps
    smartmontools
    sqlite
    sysstat
    util-linux
  ];
in {
  imports = [../../modules/agent-clis.nix];

  users.users.nicolai = {
    isNormalUser = true;
    uid = 1000;
    description = "Nicolai Schmid";
    home = homeDir;
    createHome = false;
    extraGroups = [
      "wheel"
      "libvirtd"
    ];
    openssh.authorizedKeys.keys = [keys.admin];
  };
  # The agent's whole job is root-level host work.
  security.sudo.wheelNeedsPassword = false;

  # The standalone t3 binary is dynamically linked against a generic glibc.
  programs.nix-ld.enable = true;

  environment.systemPackages =
    opsTools
    ++ (with pkgs; [
      claude-code
      codex
      gh
    ]);

  environment.etc."gitconfig".text = ''
    [user]
      name = Nicolai Schmid
      email = nicolai@schmid.uno
    [init]
      defaultBranch = main
  '';

  systemd.services.t3code-state = {
    description = "T3 Code state image on black";
    unitConfig.RequiresMountsFor = ["/var/lib"];
    path = with pkgs; [
      coreutils
      e2fsprogs
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      if [ ! -e ${image} ]; then
        touch ${image}.new
        chattr +C ${image}.new
        fallocate -l ${imageSize} ${image}.new
        mkfs.ext4 -q -L t3code-state ${image}.new
        mv ${image}.new ${image}
      fi
      mkdir -p ${stateDir}
      if ! mountpoint -q ${stateDir}; then
        mount -o loop,noatime ${image} ${stateDir}
      fi
      install -d -o nicolai -g users -m 0755 ${stateDir}
      install -d -o nicolai -g users -m 0700 ${homeDir}
      install -d -o nicolai -g users -m 0755 ${appDir} ${workspace}
      install -d -o nicolai -g users -m 1777 ${tmpDir}
    '';
  };

  systemd.services.t3code = {
    description = "T3 Code server (black ops)";
    wantedBy = ["multi-user.target"];
    requires = ["t3code-state.service"];
    after = [
      "t3code-state.service"
      "network-online.target"
      "tailscaled.service"
    ];
    wants = ["network-online.target"];
    # Same rule as atlas: never bounce the server (and the session that may be
    # running the rebuild) from a switch; restart it deliberately.
    restartIfChanged = false;

    path =
      (with pkgs; [
        bun
        nodejs_24
        claude-code
        codex
        gh
        git
        coreutils
        bash
        findutils
        gnugrep
        gnused
        gawk
        jq
        ripgrep
        openssh
        tailscale
        "/run/wrappers"
      ])
      ++ opsTools;

    environment = {
      HOME = homeDir;
      T3CODE_HOME = stateDir;
      XDG_CONFIG_HOME = "${homeDir}/.config";
      TMPDIR = tmpDir;
    };

    serviceConfig = {
      User = "nicolai";
      Group = "users";
      Restart = "on-failure";
      RestartSec = 5;

      # Hard ceiling so a runaway agent here can never take memory from the
      # atlas VM; it OOMs inside this cgroup instead. The server outlives a
      # killed child (see atlas, 2026-10-18).
      MemoryHigh = "3G";
      MemoryMax = "4G";
      MemorySwapMax = "1G";
      OOMPolicy = "continue";
      # Stay responsive while qemu saturates the host.
      CPUWeight = 400;
      IOWeight = 400;

      ExecStartPre = pkgs.writeShellScript "t3code-install" ''
        set -euo pipefail
        install -m644 "${manifest}/package.json" "${appDir}/package.json"
        install -m644 "${manifest}/bun.lock" "${appDir}/bun.lock"
        cd "${appDir}"
        ${pkgs.bun}/bin/bun install --frozen-lockfile
      '';

      ExecStart = ''
        ${pkgs.bun}/bin/bun "${appDir}/node_modules/t3/dist/bin.mjs" serve \
          --mode web --host 127.0.0.1 --port 3773 --no-browser \
          --base-dir "${stateDir}" "${workspace}"
      '';
    };
  };

  # Same CORS shim as atlas (the desktop app connects cross-origin).
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts.t3code-cors = {
      default = true;
      listen = [
        {
          addr = "127.0.0.1";
          port = 3774;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:3773";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_hide_header Access-Control-Allow-Origin;
          proxy_hide_header Access-Control-Allow-Credentials;
          add_header Access-Control-Allow-Origin $http_origin always;
          add_header Access-Control-Allow-Credentials "true" always;
          add_header Vary Origin always;
        '';
      };
    };
  };

  # Serve on black's own tailnet node: https://black.<tailnet>.
  systemd.services.t3code-tailscale-serve = {
    description = "Tailscale Serve for T3 Code on black";
    wantedBy = ["multi-user.target"];
    after = ["tailscaled.service"];
    requires = ["tailscaled.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      until ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; do sleep 2; done
      ${pkgs.tailscale}/bin/tailscale serve --bg --https=443 http://127.0.0.1:3774
    '';
  };
}
