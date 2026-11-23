# Product recovery only; never reads Atlas disks or live Convex SQLite/Garage.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.productBackup;
  names = builtins.attrNames (import ./convex/deployments.nix).deployments;
  # Per deployment: its agent source repository and its artifact store
  # (hosts/black/agent-source.nix), each only where one is declared.
  agentArgs =
    lib.genAttrs (lib.unique (builtins.attrNames cfg.agentSourceRepositories ++ builtins.attrNames cfg.agentArtifactStores))
    (name:
      lib.optionals (cfg.agentSourceRepositories ? ${name}) ["--agent-source" cfg.agentSourceRepositories.${name}]
      ++ lib.optionals (cfg.agentArtifactStores ? ${name}) ["--agent-artifacts" cfg.agentArtifactStores.${name}]);
  runner = pkgs.writeShellApplication {
    name = "product-backup";
    runtimeInputs = [pkgs.borgbackup pkgs.age pkgs.git pkgs.openssh pkgs.python3 pkgs.util-linux config.virtualisation.docker.package pkgs.systemd];
    text = ''
      extra=()
      case "$1" in
        ${lib.concatStrings (lib.mapAttrsToList (name: args: "${name}) extra=(${lib.escapeShellArgs args}) ;;\n") agentArgs)}
      esac
      export BORG_REPO=${lib.escapeShellArg cfg.repository}
      export BORG_PASSCOMMAND="cat /run/secrets/product-backup/passphrase"
      export BORG_RSH="ssh -i /run/secrets/product-backup/writer-key -p 23 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${pkgs.writeText "storage-box-known-hosts" cfg.knownHosts}"
      export BORG_REMOTE_PATH=borg-1.4
      export PRODUCT_BACKUP_SOURCE_REVISION=${lib.escapeShellArg (
        if config.system.configurationRevision == null
        then "unknown"
        else config.system.configurationRevision
      )}
      export BORG_CACHE_DIR=/var/lib/product-backup/cache
      export BORG_SECURITY_DIR=/var/lib/product-backup/security
      exec flock -w 7200 /var/lib/product-backup/lock python3 ${../../scripts/storage-box/backup.py} "$@" "''${extra[@]}" --capture-runtime ${lib.optionalString (cfg.publicRecipient != "") "--age-recipient-file ${pkgs.writeText "product-backup-public-recipient" cfg.publicRecipient}"} --state /var/lib/product-backup --secrets /var/lib/client-data/secrets --config ${../..}
    '';
  };
in {
  options.services.productBackup = {
    enable = lib.mkEnableOption "encrypted Storage Box product backups (requires provisioned repository)";
    publicRecipient = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional age or SSH public recipient; keep its private key off the writer";
    };
    agentSourceRepositories = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Deployment name to the agent source repository bundled into its backup";
    };
    agentArtifactStores = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Deployment name to the artifact store whose referenced bundles go into its backup";
    };
    pushover.enable = lib.mkEnableOption "Pushover alerts (requires an existing application token and user key)";
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
    sops.secrets = lib.genAttrs (["product-backup/writer-key" "product-backup/passphrase"] ++ lib.optional cfg.pushover.enable "product-backup/alert-config") (_: {
      mode = "0400";
      sopsFile = ../../secrets/product-backup.yaml;
    });
    sops.useSystemdActivation = true;
    system.build.productBackupRunner = runner;
    environment.systemPackages = [runner];
    systemd.tmpfiles.rules = ["d /var/lib/product-backup 0700 root root -"];
    systemd.services.product-backup-health = {
      description = "Alert on absent, stale or bundle-incomplete off-host product backup";
      after = ["sops-install-secrets.service"];
      requires = ["sops-install-secrets.service"];
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
      };
      path = [pkgs.python3];
      script = let
        alert = message:
          if cfg.pushover.enable
          then "python3 ${../../scripts/storage-box/alert.py} /run/secrets/product-backup/alert-config ${message}"
          else "echo 'Push delivery unavailable: an existing Pushover application token is required' >&2";
      in ''
        # Bit 1: missing or stale backup. Bit 2: the latest archive lacks
        # referenced hosted-workflow bundles; the backup itself succeeded.
        status=0
        python3 ${../../scripts/storage-box/health.py} /var/lib/product-backup ${lib.concatStringsSep " " names} || status=$?
        if (( status & 1 )); then
          ${alert ""}
        fi
        if (( status & 2 )); then
          ${alert "bundles"}
        fi
        if (( status != 0 )); then
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
