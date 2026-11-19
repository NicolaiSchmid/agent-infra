# E5: native trusted runner; customer code runs only inside runsc guests.
# Deployment and private artifact provisioning: runbooks/black-hosted-runner.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  runsc = import ../../modules/hosted-runner-runtime.nix {inherit pkgs;};
  # Bundle from the private eve-deployments CI; never fetch private source
  # using a credential in a Nix derivation. Provision this immutable file first.
  pin = import ./eve-deployments.nix;
  runner = "/var/lib/hosted-runner/releases/${pin.revision}/runner.mjs";
  checksum = pkgs.writeText "hosted-runner-checksum" "${pin.runner.sha256}  ${runner}\n";
  instances = {
    june-dev = {enable = true;};
    # On since 2026-11-19 for acceptance in the MODUS org, synthetic agents
    # and data only (Nicolai Schmid; June dev's Convex is in an OOM restart
    # loop). Real client data stays blocked by O2 of June's runtime plan; the
    # guard is that only staff activate releases and create installations,
    # through the operator CLI.
    june-prod = {enable = true;};
  };
  service = name: instance: let
    user = "hosted-runner-${name}";
    state = "/var/lib/${user}";
  in {
    description = "June hosted workflow runner (${name}, one delivery at a time)";
    wantedBy = lib.optionals instance.enable ["multi-user.target"];
    after = ["network-online.target" "docker.service"];
    wants = ["network-online.target"];
    requires = ["docker.service"];
    # Follow dockerd restarts so a dependency stop cannot leave polling down.
    partOf = ["docker.service"];
    path = [config.virtualisation.docker.package pkgs.util-linux pkgs.nodejs_24 pkgs.coreutils pkgs.jq];
    environment = {
      EVE_RUNNER_CONFIG = "/run/${user}/runner.json";
      EVE_JUNE_CONVEX_URL = "https://${name}.convex.modusservice.com";
      EVE_JUNE_HTTP_URL = "https://${name}-site.convex.modusservice.com";
      DOCKER_HOST = "unix:///run/docker.sock";
      TMPDIR = "${state}/tmp";
      HOME = state;
    };
    preStart = ''
      sha256sum --check --status ${checksum}
      install -d -m 0700 "${state}/tmp"
      # systemd 260 credentials are root-owned 0440. The runner requires its
      # own private regular file, so copy as the service user into /run only.
      install -m 0600 "$CREDENTIALS_DIRECTORY/runner-key" "/run/${user}/runner-key"
      # Only the environment pin comes from this root-provisioned credential
      # (agent-source.nix reports the same one with every build). Authority,
      # owner and persistent paths are fixed here, independently per deployment.
      # The runner takes any digest June admitted from the platform store and
      # verifies it per run; no artifact digest is pinned here.
      jq -e --arg state ${lib.escapeShellArg state} \
        --arg owner ${lib.escapeShellArg "black-${name}"} \
        --arg key "/run/${user}/runner-key" \
        --arg store ${lib.escapeShellArg "/var/lib/agent-artifacts/${name}"} '
        if keys != ["environment"] then error("release.json holds only {environment}") else
        {
          mode: "target-poll",
          owner: $owner,
          lockDirectory: ($state + "/locks"),
          pollIntervalMs: 1500,
          controlPlane: {backend: "june", runnerKeyFile: $key},
          artifact: {source: "store", store: $store, directory: ($state + "/artifact-cache")},
          environment: .environment
        } end' "$CREDENTIALS_DIRECTORY/release.json" > "$EVE_RUNNER_CONFIG"
      chmod 0600 "$EVE_RUNNER_CONFIG"
    '';
    unitConfig = {
      StartLimitIntervalSec = 600;
      StartLimitBurst = 10;
    };
    serviceConfig = {
      Type = "simple";
      User = user;
      Group = user;
      # Trusted host process only: Docker socket access is root-equivalent.
      # No wheel, login, provider credentials or Convex admin key.
      # agent-artifacts: read-only access to the platform store (agent-source.nix).
      SupplementaryGroups = ["docker" "agent-artifacts"];
      LoadCredential = [
        "runner-key:/root/hosted-runner/${name}-runner.key"
        "release.json:/root/hosted-runner/${name}-release.json"
      ];
      ExecStart = "${pkgs.nodejs_24}/bin/node ${runner}";
      WorkingDirectory = state;
      StateDirectory = user;
      StateDirectoryMode = "0700";
      RuntimeDirectory = user;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 30;
      # Keep the flock helper alive until custody cleanup finishes. Forced
      # termination still leaves durable proof for fail-closed recovery.
      KillMode = "mixed";
      TimeoutStopSec = "infinity";
      StandardOutput = "journal";
      StandardError = "journal";
      SyslogIdentifier = user;
      MemoryHigh = "384M";
      MemoryMax = "512M";
      MemorySwapMax = "0";
      CPUQuota = "100%";
      CPUWeight = 20;
      IOWeight = 20;
      TasksMax = 64;
      OOMScoreAdjust = 900;
      OOMPolicy = "kill";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateDevices = true;
      # Docker resolves guest bind sources in the HOST mount namespace.
      # In particular, do not enable PrivateTmp or hide the persistent paths.
      PrivateTmp = false;
      CapabilityBoundingSet = "";
      RestrictSUIDSGID = true;
    };
  };
in {
  system.build.hostedRunnerRunsc = runsc;
  environment.systemPackages = [runsc];
  # Changes daemon.json: the first switch RESTARTS DOCKER and interrupts all
  # containers, including June's Convex backends. Night maintenance only.
  virtualisation.docker.daemon.settings.runtimes.runsc = {
    path = "${runsc}/bin/runsc";
    runtimeArgs = ["--platform=systrap" "--host-uds=open"];
  };
  users.groups = lib.mapAttrs' (name: _: lib.nameValuePair "hosted-runner-${name}" {}) instances;
  users.users = lib.mapAttrs' (name: _:
    lib.nameValuePair "hosted-runner-${name}" {
      isSystemUser = true;
      group = "hosted-runner-${name}";
    })
  instances;
  systemd.services = lib.mapAttrs' (name: instance: lib.nameValuePair "hosted-runner-${name}" (service name instance)) instances;
}
