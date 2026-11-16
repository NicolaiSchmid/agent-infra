# A small T3 Code instance on black itself, for operating the host when atlas
# is the problem (memory thrash, load, disk fills, paused VM). Same pinned t3
# release as atlas, but sized to stay out of atlas's way: black has ~7G of RAM
# left next to the 52G VM.
#
# State sits on black's btrfs root under /var/lib/t3code. Since #28 the atlas
# images are fully allocated, so the VM can no longer fill that root.
#
# Reachable at https://black.<tailnet>:8443 (Serve on black's own node,
# through the same CORS shim as atlas) and via T3 Connect once linked. Not
# :443: Traefik owns that port on black and already answers for
# black.<tailnet> (its dashboard), so Serve there would take it over.
{
  config,
  pkgs,
  lib,
  ...
}: let
  keys = import ../../modules/keys.nix;
  stateDir = "/var/lib/t3code";
  appDir = "${stateDir}/app";
  homeDir = "${stateDir}/home";
  workspace = "${stateDir}/workspace";
  tmpDir = "${stateDir}/tmp";
  t3 = import ../../modules/t3-runtime.nix {
    inherit pkgs;
    baseDir = stateDir;
  };

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

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 nicolai users -"
    "d ${homeDir} 0700 nicolai users -"
    "d ${appDir} 0755 nicolai users -"
    "d ${workspace} 0755 nicolai users -"
    "d ${tmpDir} 1777 nicolai users 10d"
  ];

  systemd.services.t3code = {
    description = "T3 Code server (black ops)";
    wantedBy = ["multi-user.target"];
    after = [
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
      T3CODE_MODE = "web";
      T3CODE_HOST = "127.0.0.1";
      T3CODE_PORT = "3773";
      T3CODE_NO_BROWSER = "true";
    };

    serviceConfig = {
      User = "nicolai";
      Group = "users";
      Restart = "always";
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

      WorkingDirectory = workspace;
      ExecStartPre = t3.bootstrap;
      ExecStart = t3.command;
      KillMode = "mixed";
      TimeoutStopSec = 90;
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

  # Serve on black's own tailnet node: https://black.<tailnet>:8443.
  systemd.services.t3code-tailscale-serve = {
    description = "Tailscale Serve for T3 Code on black";
    wantedBy = ["multi-user.target"];
    after = ["tailscaled.service"];
    requires = ["tailscaled.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "always";
      RestartSec = 30;
    };
    script = ''
      until ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; do sleep 2; done
      ${pkgs.tailscale}/bin/tailscale serve --bg --https=8443 http://127.0.0.1:3774
    '';
  };
}
