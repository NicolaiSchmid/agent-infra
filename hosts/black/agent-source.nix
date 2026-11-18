# A1: the platform's agent source API, builder and artifact store (eve-deployments
# E6), one instance per June deployment. Contract: eve-deployments
# docs/agent-source.md. Scope: June's .plans/2026-11-18-agent-source-on-platform.md.
# Deployment, keys and rollback: runbooks/black-agent-source.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  keys = import ../../modules/keys.nix;
  pin = import ./eve-deployments.nix;
  runsc = import ../../modules/hosted-runner-runtime.nix {inherit pkgs;};
  toolchainPackage = import ../../modules/agent-source-toolchain.nix {inherit pkgs pin;};
  # The private source cannot be built by public CI, so the system closure
  # names the toolchain's store path without depending on it. The operator
  # realises it on black before the switch; AssertPathExists stops the units
  # otherwise, and the gcroot below keeps it.
  toolchain = builtins.unsafeDiscardStringContext "${toolchainPackage}";
  node = "${pkgs.nodejs_24}/bin/node";
  deployments = (import ./convex/deployments.nix).deployments;
  tailnet = ["100.64.0.0/10" "fd7a:115c:a1e0::/48"];
  instances = {
    june-dev = {
      enable = true;
      port = 7421;
    };
    # O2: no real client data on black yet. Defined like the E5 runner, off.
    june-prod = {
      enable = false;
      port = 7422;
    };
  };
  enabled = lib.filterAttrs (_: i: i.enable) instances;
  repository = name: "/var/lib/agent-source/${name}/repo.git";
  store = name: "/var/lib/agent-artifacts/${name}";
  # docker0: June's Convex containers resolve host.docker.internal
  # (host-gateway) to it. Their traffic arrives on their own bridge,
  # cvx-<cloudPort> (convex/compose.yaml).
  dockerHost = "172.17.0.1";
  bridge = name: "cvx-${toString deployments.${name}.cloudPort}";

  # The config holds no secrets but takes the environment pin from the
  # runner's root-provisioned release.json, so builder and runner share one.
  run = command: name: instance:
    pkgs.writeShellScript "agent-source-${name}-${command}" ''
      set -eu
      config="$RUNTIME_DIRECTORY/config.json"
      jq -e \
        --arg instance ${name} \
        --arg listen "127.0.0.1:${toString instance.port},${dockerHost}:${toString instance.port}" \
        --arg repository ${repository name} \
        --arg store ${store name} \
        --arg work /var/lib/agent-source/${name}/work \
        --arg credentials "$CREDENTIALS_DIRECTORY" \
        --arg june "http://127.0.0.1:${toString deployments.${name}.sitePort}" \
        --arg runsc ${runsc}/bin/runsc '
        {
          instance: $instance, listen: $listen,
          repository: $repository, store: $store, work: $work,
          sourceKeyFile: ($credentials + "/source-key"),
          builderKeyFile: ($credentials + "/builder-key"),
          juneOrigin: $june, runsc: $runsc, hostMounts: ["/nix/store"],
          environment: .environment
        }' "$CREDENTIALS_DIRECTORY/release.json" > "$config"
      exec ${node} ${toolchain}/scripts/agent-source.ts ${command} "$config"
    '';

  common = name: {
    path = [pkgs.git pkgs.gnutar pkgs.jq pkgs.coreutils];
    environment.HOME = "/var/lib/agent-source/${name}";
    unitConfig.AssertPathExists = "${toolchain}/scripts/agent-source.ts";
    serviceConfig = {
      User = "agent-source";
      Group = "agent-source";
      LoadCredential = [
        "source-key:/root/agent-source/${name}-source.key"
        "builder-key:/root/agent-source/${name}-builder.key"
        "release.json:/root/hosted-runner/${name}-release.json"
      ];
      StateDirectory = "agent-source/${name}";
      StateDirectoryMode = "0700";
      ReadWritePaths = [(store name)];
      UMask = "0027";
      # Loopback (June's Convex HTTP port) and the Docker bridges only.
      IPAddressDeny = "any";
      IPAddressAllow = ["127.0.0.0/8" "172.16.0.0/12"];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      # Rootless runsc needs user namespaces: no RestrictNamespaces,
      # PrivateUsers, CapabilityBoundingSet or SystemCallFilter here.
    };
  };

  services = name: instance: {
    "agent-source-${name}" = lib.recursiveUpdate (common name) {
      description = "Agent source API and builder (${name})";
      wantedBy = lib.optionals instance.enable ["multi-user.target"];
      # Only so that docker0's address exists; the builder never uses Docker.
      after = ["docker.service"];
      requires = ["docker.service"];
      serviceConfig = {
        ExecStart = run "serve" name instance;
        RuntimeDirectory = "agent-source-${name}";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = 10;
        # Exit 70: runsc could not confirm a build sandbox gone; systemd
        # kills what is left in the cgroup (default KillMode=control-group).
        KillMode = "control-group";
        MemoryMax = "3G";
        TasksMax = 512;
        SyslogIdentifier = "agent-source-${name}";
      };
    };
    "agent-source-${name}-gc" = lib.recursiveUpdate (common name) {
      description = "Agent artifact store garbage collection (${name})";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = run "gc" name instance;
        RuntimeDirectory = "agent-source-${name}-gc";
        RuntimeDirectoryMode = "0700";
      };
    };
    "agent-source-${name}-git" = {
      description = "Agent source repository maintenance (${name})";
      unitConfig.ConditionPathExists = repository name;
      path = [pkgs.git];
      environment = {
        GIT_CONFIG_NOSYSTEM = "1";
        GIT_CONFIG_GLOBAL = "/dev/null";
      };
      script = ''
        git -C ${repository name} -c core.hooksPath=/dev/null gc --auto
        git -C ${repository name} fsck --no-progress
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "agent-source";
        Group = "agent-source";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        ReadWritePaths = [(repository name)];
      };
    };
  };

  timers = name: _: {
    "agent-source-${name}-gc" = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
    "agent-source-${name}-git" = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
in {
  system.build.agentSourceToolchain = toolchainPackage;

  # Writer of every repository, store and work directory, and Nicolai's push
  # account. git-shell admits only git-receive-pack, git-upload-pack and
  # git-upload-archive.
  users.groups.agent-source = {};
  # Readers of the artifact store: the hosted runners (hosted-runner.nix).
  users.groups.agent-artifacts = {};
  users.users.agent-source = {
    isSystemUser = true;
    group = "agent-source";
    home = "/var/lib/agent-source";
    shell = "${pkgs.git}/bin/git-shell";
    openssh.authorizedKeys.keys = [keys.admin];
  };

  # OpenSSH admits agent-source only from the tailnet. On the tailnet,
  # Tailscale SSH (--ssh) answers port 22 first under the tailnet policy;
  # either way the login shell is git-shell.
  services.openssh.extraConfig = ''
    Match User agent-source
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      AllowTcpForwarding no
      PermitTTY no
      PermitTunnel no
      X11Forwarding no
    Match User agent-source Address *,${lib.concatMapStringsSep "," (range: "!${range}") tailnet}
      PubkeyAuthentication no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
  '';

  systemd.tmpfiles.rules =
    [
      "d /var/lib/agent-artifacts 0755 root root -"
      # Keep the realised toolchain across `nix-collect-garbage`.
      "L+ /nix/var/nix/gcroots/agent-source-toolchain - - - - ${toolchain}"
    ]
    # setgid: objects and records the service writes stay group-readable.
    ++ lib.mapAttrsToList (name: _: "d ${store name} 2750 agent-source agent-artifacts -") instances;

  # Each June deployment's Convex network reaches its own instance only. No
  # Traefik route and no public address. tailscale0 is trusted on black, so
  # the ports are refused there, like E2B's (e2b.nix).
  networking.firewall.extraCommands = lib.concatStrings (lib.mapAttrsToList (name: instance: ''
      ip46tables -I nixos-fw -i tailscale0 -p tcp --dport ${toString instance.port} -j nixos-fw-refuse
      ip46tables -I nixos-fw -i ${bridge name} -p tcp --dport ${toString instance.port} -j nixos-fw-accept
    '')
    instances);

  # The source repository rides along with its deployment's nightly product
  # backup. The artifact store does not: it is rebuilt from source.
  services.productBackup.agentSourceRepositories = lib.mapAttrs (name: _: repository name) enabled;

  systemd.services = lib.concatMapAttrs services instances;
  systemd.timers = lib.concatMapAttrs timers enabled;
}
