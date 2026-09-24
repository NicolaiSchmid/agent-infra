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
  manifest = "${inputs.dotfiles-src}/darwin/agents/t3code-app";
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
    install -m 0644 "${manifest}/package.json" "${appDir}/package.json"
    install -m 0644 "${manifest}/bun.lock" "${appDir}/bun.lock"
    cd "${appDir}"
    ${pkgs.bun}/bin/bun install --frozen-lockfile
    exec ${pkgs.bun}/bin/bun "${appDir}/node_modules/t3/dist/bin.mjs" serve \
      --mode web --host 127.0.0.1 --port 3773 --no-browser \
      --base-dir "${stateDir}" "${workspace}"
  '';
  linuxVmConfig = ./lima/forge-linux.yaml;
  linuxVmStart = pkgs.writeShellScript "forge-linux-start" ''
    set -euo pipefail
    export HOME="${homeDir}"
    if ${pkgs.lima}/bin/limactl list --json 2>/dev/null | ${pkgs.jq}/bin/jq -e 'select(.name == "forge-linux")' >/dev/null; then
      exec ${pkgs.lima}/bin/limactl start forge-linux
    fi
    exec ${pkgs.lima}/bin/limactl start --name=forge-linux ${linuxVmConfig}
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

  environment.systemPackages =
    cliTools
    ++ (with pkgs; [
      lima
      qemu
      rsync
    ]);

  programs.zsh.enable = true;

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
        XDG_CONFIG_HOME = "${homeDir}/.config";
        PATH = lib.makeBinPath ([
            pkgs.bun
            pkgs.nodejs_24
            pkgs.git
            pkgs.gh
            pkgs.coreutils
          ]
          ++ cliTools);
      };
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Interactive";
      StandardOutPath = "${homeDir}/Library/Logs/t3code.log";
      StandardErrorPath = "${homeDir}/Library/Logs/t3code.error.log";
    };
  };

  launchd.daemons.forge-linux = {
    command = "${linuxVmStart}";
    serviceConfig = {
      UserName = username;
      GroupName = "staff";
      RunAtLoad = true;
      StandardOutPath = "${homeDir}/Library/Logs/forge-linux.log";
      StandardErrorPath = "${homeDir}/Library/Logs/forge-linux.error.log";
    };
  };
}
