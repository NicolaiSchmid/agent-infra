# Product recovery only; never reads Atlas disks or live Convex SQLite/Garage.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.productBackup;
  names = builtins.attrNames (import ./convex/deployments.nix).deployments;
  runner = pkgs.writeShellApplication {
    name = "product-backup";
    runtimeInputs = [pkgs.borgbackup pkgs.openssh pkgs.python3 pkgs.util-linux];
    text = ''
      export BORG_REPO=${lib.escapeShellArg cfg.repository}
      export BORG_PASSCOMMAND="cat /run/secrets/product-backup/passphrase"
      export BORG_RSH="ssh -i /run/secrets/product-backup/writer-key -p 23 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pkgs.writeText "storage-box-known-hosts" cfg.knownHosts}"
      export BORG_REMOTE_PATH=borg-1.4
      export BORG_CACHE_DIR=/var/lib/product-backup/cache
      export BORG_SECURITY_DIR=/var/lib/product-backup/security
      exec flock -w 7200 /var/lib/product-backup/lock python3 ${../../scripts/storage-box/backup.py} "$@" --state /var/lib/product-backup --secrets /var/lib/client-data/secrets --config ${../..}
    '';
  };
in {
  options.services.productBackup = {
    enable = lib.mkEnableOption "encrypted Storage Box product backups (requires provisioned repository)";
    repository = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "ssh://dedicated-subaccount@host:23/./repo";
    };
    knownHosts = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Out-of-band verified [host]:23 SSH host key";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "ssh://" cfg.repository && lib.hasInfix ":23/./" cfg.repository && cfg.knownHosts != "";
        message = "Provision Storage Box repository and verified host key first";
      }
    ];
    sops.secrets = lib.genAttrs ["product-backup/writer-key" "product-backup/passphrase" "product-backup/alert-curl-config"] (_: {mode = "0400";});
    environment.systemPackages = [runner];
    systemd.tmpfiles.rules = ["d /var/lib/product-backup 0700 root root -"];
    systemd.services.product-backup-health = {
      description = "Alert on absent or stale off-host product backup";
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
      };
      path = [pkgs.python3 pkgs.curl];
      script = ''
        if ! python3 ${../../scripts/storage-box/health.py} /var/lib/product-backup ${lib.concatStringsSep " " names}; then
          curl --fail --silent --show-error --max-time 30 --config /run/secrets/product-backup/alert-curl-config
          exit 1
        fi
      '';
    };
    systemd.timers.product-backup-health = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
