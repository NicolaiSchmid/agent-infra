{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  username = "nschmid10049";
  homeDir = "/Users/${username}";
  stateDir = "${homeDir}/.local/share/t3code";
  appDir = "${stateDir}/app";
  workspace = "${homeDir}/workspace";
  # Keep Forge on its existing nightly channel; stable launcher protocol 3
  # remains compatible and leaves the Nix-owned launchd definition alone.
  t3 = import ../../modules/t3-runtime.nix {
    inherit pkgs;
    baseDir = stateDir;
    version = (builtins.fromJSON (builtins.readFile ./t3code-app/package.json)).dependencies.t3;
  };
  # Agent CLIs that T3 Code shells out to. Same pins as the MacBook, from
  # dotfiles-nix, so forge, the Mac and atlas move together.
  aiApps = import "${inputs.dotfiles-src}/darwin/packages/ai-apps.nix" {inherit pkgs;};
  agentClis = [
    aiApps.claude-code
    aiApps.codex
  ];
  cliTools = with pkgs; [
    bat
    bun
    cocoapods
    curl
    eza
    fd
    fastlane
    file
    fzf
    gh
    git
    git-lfs
    go
    htop
    jdk17
    jq
    lazygit
    lsof
    neovim
    nodejs_24
    openssh
    pnpm
    python3
    ripgrep
    rustup
    tmux
    tree
    unzip
    uv
    vim
    wget
    yarn
    zip
  ];
  t3codeStart = pkgs.writeShellScript "forge-t3code-start" ''
    set -euo pipefail
    install -d -m 0755 "${appDir}" "${workspace}"
    ${t3.bootstrap}
    cd "${workspace}"
    exec ${t3.command}
  '';
in {
  system.primaryUser = username;
  system.stateVersion = 5;

  networking = {
    hostName = "forge";
    computerName = "forge";
    localHostName = "forge";
  };

  nix = {
    settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
    optimise.automatic = true;
    gc = {
      automatic = true;
      interval = {
        Weekday = 0;
        Hour = 4;
        Minute = 15;
      };
      options = "--delete-older-than 14d";
    };
  };
  nixpkgs.config.allowUnfree = true;

  # An unattended macOS update reboot parks the machine at the FileVault unlock
  # screen and takes every runner offline; keep updates manual.
  system.defaults.SoftwareUpdate.AutomaticallyInstallMacOSUpdates = false;

  # Never sleep, on AC or battery; lid-close sleep is disabled separately with
  # `pmset -c disablesleep 1`.
  power.sleep.computer = "never";

  environment.systemPackages =
    cliTools
    ++ agentClis
    ++ (with pkgs; [
      rsync
    ]);

  programs.zsh.enable = true;

  # Storage Box product repository retention (product-backup-retention.nix).
  # Enable once secrets/product-backup-retention.yaml exists; set dryRun =
  # false only after reviewing a dry-run log (runbooks/storage-box-product-recovery.md).
  services.productBackupRetention = {
    enable = false;
    dryRun = true;
  };

  system.activationScripts.forgeState.text = ''
    install -d -o ${username} -g staff -m 0755 \
      "${homeDir}/.local" \
      "${homeDir}/.local/share" \
      "${stateDir}" \
      "${appDir}" \
      "${workspace}" \
      "${homeDir}/Library/Logs"
  '';

  launchd.daemons.t3code = {
    command = "${t3codeStart}";
    serviceConfig = {
      UserName = username;
      GroupName = "staff";
      EnvironmentVariables = {
        HOME = homeDir;
        T3CODE_HOME = stateDir;
        T3CODE_MODE = "web";
        T3CODE_HOST = "127.0.0.1";
        T3CODE_PORT = "3773";
        T3CODE_NO_BROWSER = "true";
        XDG_CONFIG_HOME = "${homeDir}/.config";
        PATH = lib.makeBinPath ([
            pkgs.bun
            pkgs.nodejs_24
            pkgs.git
            pkgs.gh
            pkgs.coreutils
          ]
          ++ cliTools
          ++ agentClis);
      };
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Interactive";
      ExitTimeOut = 90;
      AbandonProcessGroup = false;
      StandardOutPath = "${homeDir}/Library/Logs/t3code.log";
      StandardErrorPath = "${homeDir}/Library/Logs/t3code.error.log";
    };
  };
}
