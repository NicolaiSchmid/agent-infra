{
  config,
  pkgs,
  lib,
  ...
}: let
  keys = import ../../modules/keys.nix;
in {
  imports = [
    ./disko.nix
    ./libvirt.nix
    ./networking.nix
    ./sops.nix
  ];

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    mirroredBoots = [
      {
        devices = ["nodev"];
        path = "/boot";
      }
      {
        devices = ["nodev"];
        path = "/boot-fallback";
      }
    ];
  };
  boot.loader.efi.canTouchEfiVariables = false;

  boot.supportedFilesystems = ["btrfs"];
  boot.initrd.supportedFilesystems = ["btrfs"];
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = ["kvm-amd"];

  networking.hostName = "black";
  time.timeZone = "Europe/Berlin";

  users.mutableUsers = false;
  users.users.root.openssh.authorizedKeys.keys = [keys.admin];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.tailscale = {
    enable = true;
    authKeyFile = lib.mkIf (config.sops.secrets ? "tailscale/black-authkey") config.sops.secrets."tailscale/black-authkey".path;
    port = 41640;
    extraUpFlags = [
      "--ssh"
      "--hostname=black"
    ];
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = ["tailscale0"];
    allowedTCPPorts = [22];
    allowedUDPPorts = [config.services.tailscale.port];
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

  environment.systemPackages = with pkgs; [
    btrfs-progs
    git
    htop
    jq
    lsof
    ripgrep
    tmux
    vim
  ];

  # The host should have a pressure buffer, but atlas gets the real memory.
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };

  system.stateVersion = "25.11";
}
