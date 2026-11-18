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
  release = {
    revision = "98690a849440934094bc555765518c26ebff0e0d";
    sha256 = "bc5f114f837e5afedb9fd73b226ac4cc462de2b1db41dc5a15168348f35e9231";
  };
  runner = "/var/lib/hosted-runner/releases/${release.revision}/runner.mjs";
  checksum = pkgs.writeText "hosted-runner-checksum" "${release.sha256}  ${runner}\n";
  instances = {
    june-dev = {enable = true;};
    # O2: test-data pilot first. Enabling prod requires a separate change
    # after live acceptance and the decision about real client data on black.
    june-prod = {enable = false;};
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
      # Only release pins come from this root-provisioned credential. Authority,
      # owner and persistent paths are fixed here, independently per deployment.
      jq -e --arg state ${lib.escapeShellArg state} \
        --arg owner ${lib.escapeShellArg "black-${name}"} \
        --arg key "/run/${user}/runner-key" '
        {
          mode: "target-poll",
          owner: $owner,
          lockDirectory: ($state + "/locks"),
          pollIntervalMs: 1500,
          controlPlane: {backend: "june", runnerKeyFile: $key},
          artifact: {
            source: "june", directory: ($state + "/artifacts"),
            digest: .artifact.digest, entrypoint: .artifact.entrypoint
          },
          environment: .environment
        }' "$CREDENTIALS_DIRECTORY/release.json" > "$EVE_RUNNER_CONFIG"
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
      SupplementaryGroups = ["docker"];
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
