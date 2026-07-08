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
    "${agentModules}/home.nix"
    "${agentModules}/t3code.nix"
    "${agentModules}/hermes.nix"
    "${agentModules}/process-watch.nix"
  ];

  boot.loader.grub.enable = true;
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
