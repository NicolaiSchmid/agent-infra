# Automatic 30-day retention for the off-host product Borg repository
# (runbooks/storage-box-product-recovery.md, "Retention").
#
# Black may only append (its writer key is forced to `borg serve
# --append-only`), so pruning needs a second key without --append-only. That
# authority lives here, not on Black or Atlas: Forge is always on, and the key
# and passphrase are root-only SOPS files that the nschmid10049 account (T3
# Code, GitHub runners) cannot read. The SOPS file is encrypted to Forge's host
# key and the operator only, never to Black.
#
# Daily at 12:15, well clear of Black's 03:30-04:00 writes: delete archives
# older than `keepDays` (a current deployment always keeps its newest), then
# compact. `dryRun` (the default) only lists what would be pruned.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.productBackupRetention;
  target = import ../storage-box-repository.nix;
  current = builtins.attrNames (import ../black/convex/deployments.nix).deployments;
  stateDir = "/var/lib/product-backup-retention";
  logFile = "/var/log/product-backup-retention.log";
  secret = name: config.sops.secrets."product-backup-retention/${name}".path;
  job = pkgs.writeShellApplication {
    name = "product-backup-retention";
    runtimeInputs = [pkgs.borgbackup pkgs.openssh pkgs.python3 pkgs.coreutils];
    text = ''
      export BORG_REPO=${lib.escapeShellArg target.repository}
      export BORG_PASSCOMMAND=${lib.escapeShellArg "cat ${secret "passphrase"}"}
      export BORG_RSH=${lib.escapeShellArg "ssh -i ${secret "ssh-key"} -p 23 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pkgs.writeText "storage-box-known-hosts" target.knownHosts}"}
      export BORG_REMOTE_PATH=borg-1.4
      export BORG_CACHE_DIR=${stateDir}/cache
      export BORG_SECURITY_DIR=${stateDir}/security
      export BORG_CONFIG_DIR=${stateDir}/config
      umask 077
      install -d -m 0700 ${stateDir}
      echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) retention keep-days=${toString cfg.keepDays}${lib.optionalString cfg.dryRun " (dry-run)"}"
      status=0
      python3 ${../../scripts/storage-box/retention.py} --state ${stateDir} \
        --keep-days ${toString cfg.keepDays} --current ${lib.concatStringsSep " " current} \
        ${lib.optionalString cfg.dryRun "--dry-run"} || status=$?
      if [ "$status" -ne 0 ]; then
        echo "Retention failed with status $status" >&2
        ${
        if cfg.pushover.enable
        then "python3 ${../../scripts/storage-box/alert.py} ${secret "alert-config"} retention || echo 'Retention alert delivery failed' >&2"
        else "echo 'Push delivery unavailable: an existing Pushover application token is required' >&2"
      }
      fi
      exit "$status"
    '';
  };
in {
  options.services.productBackupRetention = {
    enable = lib.mkEnableOption "scheduled prune/compact of the Storage Box product repository (requires secrets/product-backup-retention.yaml)";
    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "List what would be pruned; never prune or compact";
    };
    keepDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Archives older than this many days are deleted (AVV Anlage 2: 30 days)";
    };
    pushover.enable = lib.mkEnableOption "Pushover alerts on retention failure (requires product-backup-retention/alert-config)";
  };

  config = lib.mkIf cfg.enable {
    sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    sops.secrets = lib.genAttrs (map (n: "product-backup-retention/${n}") (["ssh-key" "passphrase"] ++ lib.optional cfg.pushover.enable "alert-config")) (_: {
      mode = "0400";
      sopsFile = ../../secrets/product-backup-retention.yaml;
    });
    system.build.productBackupRetention = job;
    environment.systemPackages = [job];
    launchd.daemons.product-backup-retention = {
      command = "${job}/bin/product-backup-retention";
      serviceConfig = {
        StartCalendarInterval = [
          {
            Hour = 12;
            Minute = 15;
          }
        ];
        RunAtLoad = false;
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };
  };
}
