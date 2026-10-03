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
  ghPrShim = pkgs.writeShellScriptBin "gh" ''
    export GH_PR_SHIM_REAL_GH=${pkgs.gh}/bin/gh
    exec ${pkgs.nodejs_24}/bin/node ${./gh-pr-shim.mjs} "$@"
  '';
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./disko.nix
    ./sops.nix
    ./tailscale.nix
    ./forge-runner-watchdog.nix
    ./github-runners.nix
    "${agentModules}/tailscale-uis.nix"
    "${agentModules}/home.nix"
    "${agentModules}/t3code.nix"
    "${agentModules}/hermes.nix"
    "${agentModules}/process-watch.nix"
  ];

  nixpkgs.overlays = [
    (final: prev: {
      claude-code = prev.claude-code.overrideAttrs (_old: {
        version = "2.1.288";
        src = final.fetchurl {
          url = "https://downloads.claude.ai/claude-code-releases/2.1.288/linux-x64/claude";
          hash = "sha256-ApgGi2huf9uvlAKnpYe7f0nAsOCE3gn2kUWgcZIHZAw=";
        };
      });

      codex = final.stdenvNoCC.mkDerivation rec {
        pname = "codex";
        version = "0.160.0";

        src = final.fetchurl {
          url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-x86_64-unknown-linux-musl.tar.gz";
          hash = "sha256-MGhlQX1O56kneFhSkQpSf0Hh4Vmt05CsWuOsy2fUShM=";
        };

        codeModeHostSrc = final.fetchurl {
          url = "https://github.com/openai/codex/releases/download/rust-v${version}/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz";
          hash = "sha256-rGzWKI8OOfRqM+uhz9N3EWUfFPM9vHPWobgutF4DjKw=";
        };

        nativeBuildInputs = [final.makeWrapper];

        unpackPhase = ''
          tar -xzf "$src"
          tar -xzf "$codeModeHostSrc"
        '';

        installPhase = ''
          runHook preInstall

          install -Dm755 codex-x86_64-unknown-linux-musl "$out/bin/codex"
          install -Dm755 codex-code-mode-host-x86_64-unknown-linux-musl "$out/bin/codex-code-mode-host"
          wrapProgram "$out/bin/codex" \
            --prefix PATH : ${final.lib.makeBinPath [
            final.bubblewrap
            final.ripgrep
          ]}

          runHook postInstall
        '';

        meta =
          prev.codex.meta
          // {
            sourceProvenance = [final.lib.sourceTypes.binaryNativeCode];
            platforms = ["x86_64-linux"];
          };
      };

      opencode = final.stdenvNoCC.mkDerivation rec {
        pname = "opencode";
        version = "1.18.32";

        src = final.fetchurl {
          url = "https://github.com/anomalyco/opencode/releases/download/v${version}/opencode-linux-x64.tar.gz";
          hash = "sha256-MEbgQE/cYPuAMH56R4JLoHR3NkF4pNCbqoVISW3W1Ds=";
        };

        unpackPhase = ''
          tar -xzf "$src"
        '';

        installPhase = ''
          install -Dm755 opencode "$out/bin/opencode"
        '';

        meta = {
          description = "AI coding agent built for the terminal";
          homepage = "https://opencode.ai";
          sourceProvenance = [final.lib.sourceTypes.binaryNativeCode];
          platforms = ["x86_64-linux"];
        };
      };
    })
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

  # Both virtio disks are sparse raw files on black with discard=unmap. ext4 is
  # mounted without `discard`, so freed blocks never reach the host until fstrim
  # runs: on 2026-10-01 the guest used 508 GiB of /srv/agents-state while the
  # host image had grown to 735 GiB, black's btrfs hit 100 % and qemu paused the
  # VM (io-error). A daily trim keeps the images close to real usage.
  # Every 15 min: between trims the image grows by every block the guest
  # allocates in a previously punched hole (~100 GB/h under agent load on
  # 2026-10-03), so the trim period bounds how much host headroom is needed.
  services.fstrim = {
    enable = true;
    interval = "*:0/15";
  };
  # Upstream fstrim.timer ships AccuracySec=1h and RandomizedDelaySec=100min,
  # which would turn the 15-minute schedule into roughly hourly at best.
  systemd.timers.fstrim.timerConfig = {
    AccuracySec = "1min";
    RandomizedDelaySec = "0";
  };

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
    "d /srv/agents-state/hermes/tmp 1777 root root -"
    "d /srv/agents-state/nicolai 0700 nicolai users -"
    "d /srv/agents-state/secrets 0700 root root -"
    "d /srv/agents-state/t3code 0755 nicolai users -"
    "d /srv/agents-state/workspace 0755 nicolai users -"
    "L+ /srv/agents-state/t3code/.aliases - - - - /srv/agents-state/nicolai/.aliases"
    "L+ /srv/agents-state/t3code/.zshenv - - - - /srv/agents-state/nicolai/.zshenv"
    "L+ /srv/agents-state/t3code/.zshrc - - - - /srv/agents-state/nicolai/.zshrc"
    # Agent temp lives on the state disk (see the /tmp block below). The Node
    # compile cache (npm CLI + vitest enable it, no eviction) is redirected there
    # for anything that still resolves os.tmpdir() to /tmp.
    "d /srv/agents-state/tmp 1777 root root 10d"
    "d /srv/agents-state/tmp/node-compile-cache 1777 root root -"
    "L+ /tmp/node-compile-cache - - - - /srv/agents-state/tmp/node-compile-cache"
    "x /tmp/node-compile-cache"
  ];

  # /tmp sits on the 118G root disk (vda2) and filled it on 2026-09-28: agents
  # clone and build straight into /tmp, and npm/vitest keep an unbounded Node
  # compile cache there (20G, ~1M files). t3code errored with SQLITE_FULL because
  # SQLite temp files also go to /tmp. So: agent processes get TMPDIR on the 1 TB
  # state disk, and the root-disk /tmp is aged after 2 days instead of 10.
  boot.tmp.cleanOnBoot = true;
  environment.etc."tmpfiles.d/tmp.conf".text = ''
    q /tmp 1777 root root 2d
    q /var/tmp 1777 root root 14d
  '';
  environment.sessionVariables.TMPDIR = "/srv/agents-state/tmp";

  # Journal and core dumps share the root disk too; cap them. dhcpcd dumped core
  # 300+ times (2G) because it tried to manage Docker veth interfaces and
  # crashed in ipv6nd_expire when they vanished -- only enp1s0 needs DHCP.
  services.journald.extraConfig = ''
    SystemMaxUse=1G
    SystemKeepFree=5G
  '';
  systemd.coredump.settings.Coredump = {
    MaxUse = "512M";
    KeepFree = "5G";
  };
  networking.dhcpcd.allowInterfaces = ["enp1s0"];

  system.activationScripts.removeBrokenAgentHomeLinks.text = ''
    for base in /srv/agents-state/nicolai /root; do
      for rel in .zshrc .zshenv .aliases .config/git/config; do
        path="$base/$rel"
        if [ -L "$path" ] && [ ! -e "$path" ]; then
          rm "$path"
        fi
      done
    done
  '';

  systemd.services.t3code = {
    path = lib.mkBefore [ghPrShim];
    # Inherited by every claude/codex/opencode process t3code spawns.
    environment.TMPDIR = "/srv/agents-state/tmp";
    # Operational rule (README): t3code carries live agent work, so a rebuild
    # must never bounce it. Unit changes are picked up by a manual
    # `systemctl restart t3code` in a planned window.
    restartIfChanged = false;
  };

  systemd.services.hermes.serviceConfig.ExecStart = lib.mkForce ''
    ${pkgs.docker}/bin/docker run --rm --name hermes \
      --network host \
      --mount type=bind,source=/srv/agents-state/hermes/data,target=/opt/data \
      --mount type=bind,source=/srv/agents-state/secrets/hermes_ssh,target=/secrets/hermes_ssh,readonly \
      --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
      --tmpfs /var/tmp:rw,nosuid,nodev,mode=1777 \
      --env-file /srv/agents-state/secrets/hermes-dashboard.env \
      -e HERMES_UID=1000 -e HERMES_GID=100 \
      -e HERMES_DASHBOARD=1 \
      -e TERMINAL_ENV=ssh \
      -e TERMINAL_SSH_HOST=127.0.0.1 \
      -e TERMINAL_SSH_USER=nicolai \
      -e TERMINAL_SSH_PORT=22 \
      -e TERMINAL_SSH_KEY=/secrets/hermes_ssh \
      hermes-agent:latest gateway run
  '';

  systemd.services.hermes.unitConfig.ConditionPathExists = [
    "/srv/agents-state/secrets/hermes-dashboard.env"
    "/srv/agents-state/secrets/hermes_ssh"
  ];

  systemd.services.hermes-serve.unitConfig.ConditionPathExists = [
    "/srv/agents-state/secrets/hermes-dashboard.env"
    "/srv/agents-state/secrets/hermes_ssh"
  ];

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

  systemd.services.tailscale-t3code-serve.script = lib.mkForce ''
    sock=/run/tailscale-t3code/tailscaled.sock
    if ! ${pkgs.tailscale}/bin/tailscale --socket="$sock" status --json | ${pkgs.jq}/bin/jq -e '.BackendState == "Running"' >/dev/null; then
      if [ -s /srv/agents-state/secrets/tailscale.authkey ]; then
        ${pkgs.tailscale}/bin/tailscale --socket="$sock" up --authkey="$(cat /srv/agents-state/secrets/tailscale.authkey)" --hostname=atlas-t3code --accept-dns=false --ssh
      else
        ${pkgs.tailscale}/bin/tailscale --socket="$sock" up --hostname=atlas-t3code --accept-dns=false --ssh
      fi
    fi
    ${pkgs.tailscale}/bin/tailscale --socket="$sock" set --ssh=true
    ${pkgs.tailscale}/bin/tailscale --socket="$sock" serve --bg --https=443 "http://127.0.0.1:3774"
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
      opencode
      tailscale
      tmux
      vim
    ]);

  environment.etc."gitconfig".text = ''
    [user]
      name = Nicolai Schmid
      email = nicolai@schmid.uno
    [init]
      defaultBranch = main
  '';

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
