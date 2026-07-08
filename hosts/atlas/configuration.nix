{
  config,
  pkgs,
  lib,
  inputs,
  modulesPath,
  ...
}: let
  keys = import ../../modules/keys.nix;
  agentModules = "${inputs.dotfiles-src}/darwin/agents";
  cliTools = import "${inputs.dotfiles-src}/darwin/packages/cli-tools.nix" {inherit pkgs;};
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
    ./sops.nix
    ./tailscale.nix
    "${agentModules}/tailscale-uis.nix"
    "${agentModules}/home.nix"
    "${agentModules}/t3code.nix"
    "${agentModules}/hermes.nix"
    "${agentModules}/process-watch.nix"
  ];

  boot.loader.grub = {
    enable = true;
    devices = lib.mkForce [];
    mirroredBoots = lib.mkForce [
      {
        devices = ["/dev/vda"];
        path = "/boot";
      }
    ];
  };
  boot.growPartition = true;
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];
  boot.kernel.sysctl."net.ipv4.ping_group_range" = "0 2147483647";

  networking = {
    hostName = "atlas";
    useDHCP = lib.mkDefault true;
    firewall = {
      enable = true;
      trustedInterfaces = ["tailscale0"];
      allowedUDPPorts = [
        config.services.tailscale.port
        41642
      ];
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  users.mutableUsers = false;
  users.users.root = {
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [keys.admin];
  };
  users.users.nicolai = {
    isNormalUser = true;
    uid = 1000;
    description = "Nicolai Schmid";
    home = "/srv/agents-state/nicolai";
    createHome = true;
    extraGroups = [
      "wheel"
      "docker"
    ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      keys.admin
      keys.hermes
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  systemd.tmpfiles.rules = [
    "d /srv/agents-state 0755 root root -"
    "d /srv/agents-state/hermes 0755 root root -"
    "d /srv/agents-state/hermes/data 0755 root root -"
    "d /srv/agents-state/nicolai 0700 nicolai users -"
    "d /srv/agents-state/secrets 0700 root root -"
    "d /srv/agents-state/t3code 0755 nicolai users -"
    "d /srv/agents-state/workspace 0755 nicolai users -"
  ];

  systemd.services.hermes.unitConfig.ConditionPathExists = [
    "/srv/agents-state/secrets/hermes-dashboard.env"
    "/srv/agents-state/secrets/hermes_ssh"
  ];

  systemd.services.hermes-serve.unitConfig.ConditionPathExists = [
    "/srv/agents-state/secrets/hermes-dashboard.env"
    "/srv/agents-state/secrets/hermes_ssh"
  ];

  systemd.services.tailscale-t3code-serve.script = lib.mkForce ''
    sock=/run/tailscale-t3code/tailscaled.sock
    if ! ${pkgs.tailscale}/bin/tailscale --socket="$sock" status --json | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
      if [ -s /srv/agents-state/secrets/tailscale.authkey ]; then
        ${pkgs.tailscale}/bin/tailscale --socket="$sock" up --authkey="$(cat /srv/agents-state/secrets/tailscale.authkey)" --hostname=t3code --accept-dns=false
      else
        ${pkgs.tailscale}/bin/tailscale --socket="$sock" up --hostname=t3code --accept-dns=false
      fi
    fi
    ${pkgs.tailscale}/bin/tailscale --socket="$sock" serve --bg --https=443 "http://127.0.0.1:3773"
    exec sleep infinity
  '';

  systemd.services.agents-process-watch.serviceConfig.ExecStart = lib.mkForce (pkgs.writeShellScript "agents-process-watch" ''
    set -euo pipefail

    ${pkgs.procps}/bin/ps -eo pid=,ppid=,etimes=,pcpu=,pmem=,comm=,args= |
      ${pkgs.gawk}/bin/awk '
        function emit(reason, line) {
          cmd = "${pkgs.util-linux}/bin/logger -t agents-process-watch -- " q reason ": " line q
          system(cmd)
        }

        BEGIN {
          q = sprintf("%c", 39)
        }

        {
          pid = $1
          ppid = $2
          etimes = $3 + 0
          pcpu = $4 + 0
          pmem = $5 + 0
          comm = $6

          args = $0
          sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9.]+[[:space:]]+[0-9.]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", args)

          if ((index(args, "glob.glob(") || index(args, "glob(")) && index(args, "/**/")) {
            emit("root recursive glob", $0)
          } else if (comm ~ /^python/ && args ~ /python3? -/ && etimes > 1800 && pcpu > 80) {
            emit("long high-cpu stdin python", $0)
          } else if (args ~ /(^|[[:space:]])rm[[:space:]]+-[^[:space:]]*i/ && etimes > 900) {
            emit("stuck interactive rm", $0)
          } else if ((args ~ /codex exec/ || args ~ /claude --/) && etimes > 21600 && pcpu > 50) {
            emit("long high-cpu agent subprocess", $0)
          }
        }
      '
  '');

  fileSystems."/var/lib/tailscale" = {
    device = "/srv/agents-state/tailscale";
    fsType = "none";
    options = [
      "bind"
      "x-systemd.requires-mounts-for=/srv/agents-state"
    ];
  };

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages =
    cliTools
    ++ (with pkgs; [
      btrfs-progs
      claude-code
      codex
      chromium
      git
      htop
      jq
      lsof
      tailscale
      tmux
      vim
    ]);

  programs.zsh.enable = true;
  users.defaultUserShell = pkgs.zsh;

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    zstd
    openssl
    curl
    icu
    libgcc
    glib
    nss
    nspr
    atk
    at-spi2-atk
    at-spi2-core
    cups
    dbus
    expat
    cairo
    pango
    gdk-pixbuf
    gtk3
    libdrm
    libxkbcommon
    mesa
    libgbm
    systemd
    alsa-lib
    fontconfig
    freetype
    libGL
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxrender
    libxtst
    libxi
    libxcb
    libxscrnsaver
    libxshmfence
  ];

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  time.timeZone = "Europe/Berlin";
  system.stateVersion = "25.11";
}
