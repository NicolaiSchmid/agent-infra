# Self-hosted libSQL (sqld) for June's executor database: the Executor SDK's
# integration registry, which June's Convex opens on every chat turn. It
# replaces Turso Cloud for that role (June repository,
# docs/infrastructure/executor-database.md). Operations and the data move:
# runbooks/black-executor-db.md.
#
# Per instance <name> (executor-db/instances.nix), from the template
# executor-db/compose.yaml:
# - server in compose project executor-db-<name>: data in
#   <stateDir>/executor-db/<name>, reached by its one Convex backend on the
#   internal docker network executor-db-<name> as
#   http://executor-db-<name>:8080 (convex.nix joins the backend to it), and
#   by the host on 127.0.0.1:<port>; never on Traefik;
# - secrets/executor-db-<name>-jwt.key (Ed25519, root, 0600), generated once;
#   the server gets only the public half. `executor-db-token <name>` signs a
#   token with it; `executor-db-convex-env <name>` writes the URL and a token
#   into the Convex deployment's environment (operator-run, never by a unit);
# - executor-db-<name>-backup.timer: a daily SQL dump into the Garage bucket
#   executor-db-<name>-backups, kept 30 days (newest always kept);
# - executor-db-<name>-health.timer: every 5 minutes, /health and an
#   authenticated read; a failure of either timer raises the fixed
#   executor-db alert (scripts/storage-box/alert.py).
# All instances share executordb.slice, outside client-data.slice, so a
# demo deployment's memory spike cannot take the registry with it.
{stateDir}: {
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (import ./executor-db/instances.nix) instances;
  docker = "${config.virtualisation.docker.package}/bin/docker";
  secrets = "${stateDir}/secrets";

  dataDir = name: "${stateDir}/executor-db/${name}";
  keyFile = name: "${secrets}/executor-db-${name}-jwt.key";
  pubFile = name: "${secrets}/executor-db-${name}-jwt.pub";
  backupSecretsFile = name: "${secrets}/executor-db-${name}-backup.env";
  network = name: "executor-db-${name}";
  envFile = name: i:
    pkgs.writeText "executor-db-${name}.env" ''
      EXECDB_NAME=${name}
      EXECDB_DATA_DIR=${dataDir name}
      EXECDB_JWT_PUB=${pubFile name}
      EXECDB_PORT=${toString i.port}
      EXECDB_MEMORY=${i.memory}
    '';
  compose = name: i: "${docker} compose -p executor-db-${name} --project-directory ${dataDir name} -f ${./executor-db/compose.yaml} --env-file ${envFile name i}";

  # Signs a JWT for sqld with an instance's key: `executor-db-token <name>
  # [rw|ro] [seconds]`. Without seconds the token does not expire; it stops
  # working when the key is replaced (runbook: rotate the key).
  token = pkgs.writeShellApplication {
    name = "executor-db-token";
    runtimeInputs = with pkgs; [openssl coreutils];
    text = ''
      name=''${1:?usage: executor-db-token <name> [rw|ro] [seconds]}
      access=''${2:-rw}
      case "$access" in rw | ro) ;; *) echo "access must be rw or ro" >&2; exit 2 ;; esac
      case "$name" in ${lib.concatStringsSep " | " (lib.attrNames instances)}) ;; *) echo "unknown instance $name" >&2; exit 2 ;; esac
      key=${secrets}/executor-db-$name-jwt.key
      b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
      claims="{\"a\":\"$access\""
      if [ -n "''${3:-}" ]; then claims="$claims,\"exp\":$(( $(date +%s) + $3 ))"; fi
      claims="$claims}"
      header=$(printf '{"alg":"EdDSA","typ":"JWT"}' | b64url)
      payload=$(printf '%s' "$claims" | b64url)
      msg=$(mktemp)
      trap 'rm -f "$msg"' EXIT
      printf '%s.%s' "$header" "$payload" > "$msg"
      signature=$(openssl pkeyutl -sign -rawin -inkey "$key" -in "$msg" | b64url)
      printf '%s.%s.%s\n' "$header" "$payload" "$signature"
    '';
  };

  # Points an instance's Convex deployment at it: sets EXECUTOR_DATABASE_URL
  # and a new read-write EXECUTOR_DATABASE_AUTH_TOKEN through the backend's
  # admin API on loopback. Prints only the variable names. The cutover step of
  # the runbook; no unit runs it.
  convexEnv = pkgs.writeShellApplication {
    name = "executor-db-convex-env";
    runtimeInputs = with pkgs; [curl jq coreutils];
    text = ''
      name=''${1:?usage: executor-db-convex-env <name>}
      case "$name" in
        ${lib.concatStrings (lib.mapAttrsToList (n: i: ''
          ${n}) convex=${i.convex}; port=${toString (import ./convex/deployments.nix).deployments.${i.convex}.cloudPort} ;;
        '')
        instances)}
        *) echo "unknown instance $name" >&2; exit 2 ;;
      esac
      value=$(${token}/bin/executor-db-token "$name" rw)
      jq -n --arg url "http://executor-db-$name:8080" --arg token "$value" \
        '{changes: [{name: "EXECUTOR_DATABASE_URL", value: $url}, {name: "EXECUTOR_DATABASE_AUTH_TOKEN", value: $token}]}' |
        curl -fsS -X POST -H "Authorization: Convex $(cat ${secrets}/convex-$convex-admin-key)" \
          -H 'content-type: application/json' --data-binary @- \
          "http://127.0.0.1:$port/api/update_environment_variables" >/dev/null
      echo "convex-$convex: set EXECUTOR_DATABASE_URL=http://executor-db-$name:8080 and EXECUTOR_DATABASE_AUTH_TOKEN"
    '';
  };

  health = name: i:
    pkgs.writeShellApplication {
      name = "executor-db-${name}-health";
      runtimeInputs = with pkgs; [curl jq coreutils];
      text = ''
        url=http://127.0.0.1:${toString i.port}
        curl -fsS --max-time 10 "$url/health" >/dev/null
        auth="Authorization: Bearer $(${token}/bin/executor-db-token ${name} ro 300)"
        result=$(curl -fsS --max-time 10 -H "$auth" -H 'content-type: application/json' -X POST "$url/v2/pipeline" \
          -d '{"requests":[{"type":"execute","stmt":{"sql":"select count(*) from sqlite_master"}}]}')
        [ "$(jq -r '.results[0].type' <<<"$result")" = ok ] || { echo "authenticated read failed: $(jq -c '.results[0].error // .' <<<"$result")" >&2; exit 1; }
      '';
    };

  backup = name: i:
    pkgs.writeShellApplication {
      name = "executor-db-${name}-backup";
      runtimeInputs = with pkgs; [curl rclone gzip coreutils gnugrep];
      text = ''
        url=http://127.0.0.1:${toString i.port}
        set -a
        # shellcheck source=/dev/null
        . ${backupSecretsFile name}
        set +a
        export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
          RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 RCLONE_CONFIG_GARAGE_REGION=garage \
          RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
          RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
        dest=garage:executor-db-${name}-backups/daily

        umask 077
        dump=$(mktemp)
        trap 'rm -f "$dump" "$dump.gz"' EXIT
        # sqld's /dump: one consistent SQL text of the whole database, the
        # same format a restore replays (runbook: restore).
        curl -fsS --max-time 600 -H "Authorization: Bearer $(${token}/bin/executor-db-token ${name} ro 900)" "$url/dump" -o "$dump"
        tail -n 1 "$dump" | grep -qx 'COMMIT;' || { echo "dump does not end in COMMIT" >&2; exit 1; }
        gzip -9 "$dump"
        rclone copyto "$dump.gz" "$dest/$(date -u +%Y-%m-%dT%H%M%SZ).sql.gz"
        echo "dumped $(stat -c %s "$dump.gz") bytes (gzip)"

        # 30 days, the same as the Convex backups (convex.nix); never the
        # newest. Names start with their UTC time.
        cutoff=$(date -u -d '30 days ago' +%Y-%m-%dT%H%M%SZ)
        rclone lsf "$dest" | sort | head -n -1 | while read -r old; do
          [[ "$old" < "$cutoff" ]] || continue
          rclone deletefile "$dest/$old"
          echo "removed $old"
        done
      '';
    };

  # Garage bucket and a key with access to only that bucket, for one
  # instance's backups. Idempotent; runs before each backup, so the server
  # itself never waits for Garage.
  provisionBackup = name:
    pkgs.writeShellScript "executor-db-${name}-backup-provision" ''
      set -eu
      PATH=${lib.makeBinPath [config.virtualisation.docker.package pkgs.gawk pkgs.coreutils]}
      g() { docker exec garage /garage "$@"; }
      bucket=executor-db-${name}-backups
      g bucket info "$bucket" >/dev/null 2>&1 || g bucket create "$bucket"
      g key info "$bucket" >/dev/null 2>&1 || g key create "$bucket" >/dev/null
      g bucket allow --read --write --owner "$bucket" --key "$bucket" >/dev/null
      file=${backupSecretsFile name}
      if [ ! -s "$file" ]; then
        umask 077
        info=$(g key info "$bucket" --show-secret)
        {
          echo "AWS_ACCESS_KEY_ID=$(awk '/^Key ID:/ {print $3}' <<<"$info")"
          echo "AWS_SECRET_ACCESS_KEY=$(awk '/^Secret key:/ {print $3}' <<<"$info")"
        } > "$file.tmp"
        mv "$file.tmp" "$file"
      fi
    '';

  # Black's one alert path (hosted-runner.nix): Pushover once an application
  # token exists, until then a fixed journal line. At most one push per unit
  # and hour, since the health timer fails every 5 minutes while a server is
  # down.
  pushover = config.services.productBackup.pushover.enable;
  failureAlert = {
    description = "Alert that executor database unit %i failed";
    after = lib.optional pushover "sops-install-secrets.service";
    path = [pkgs.python3 pkgs.coreutils pkgs.findutils];
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
    };
    scriptArgs = "%i";
    script = ''
      echo "<2>Executor database unit $1 failed; June integrations may be down. See runbooks/black-executor-db.md" >&2
      stamp=/var/lib/executor-db-alerts/$1
      mkdir -p /var/lib/executor-db-alerts
      if [ -n "$(find "$stamp" -mmin -60 2>/dev/null)" ]; then
        echo "alerted for $1 within the last hour; not pushing again" >&2
        exit 0
      fi
      touch "$stamp"
      ${
        if pushover
        then ''python3 ${../../scripts/storage-box/alert.py} /run/secrets/product-backup/alert-config executor-db "$1"''
        else "echo '<3>Push delivery unavailable: an existing Pushover application token is required' >&2"
      }
    '';
  };

  instanceServices = name: i: {
    "executor-db-${name}" = {
      description = "libSQL server for June executor database ${name}";
      wantedBy = ["multi-user.target"];
      after = ["docker.service" "executordb.slice"];
      requires = ["docker.service" "executordb.slice"];
      # Convex joins this server's network; starting it after the server lets
      # it find the network on a fresh host (convex.nix creates it too).
      before = ["convex-${i.convex}.service"];
      reloadIfChanged = true;
      path = [config.virtualisation.docker.package pkgs.openssl pkgs.coreutils];
      preStart = ''
        mkdir -p ${dataDir name}
        docker network inspect ${network name} >/dev/null 2>&1 || docker network create --internal ${network name} >/dev/null
        if [ ! -s ${keyFile name} ]; then
          umask 077
          openssl genpkey -algorithm ed25519 -out ${keyFile name}.tmp
          mv ${keyFile name}.tmp ${keyFile name}
        fi
        # The public half is not secret; the server reads it as its own user.
        openssl pkey -in ${keyFile name} -pubout -out ${pubFile name}.tmp
        chmod 0644 ${pubFile name}.tmp
        mv ${pubFile name}.tmp ${pubFile name}
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5min";
        ExecStart = "${compose name i} up -d --wait --remove-orphans";
        ExecReload = "${compose name i} up -d --wait --remove-orphans";
        ExecStop = "${compose name i} down";
      };
    };

    "executor-db-${name}-backup" = {
      description = "Dump executor database ${name} into Garage";
      after = ["executor-db-${name}.service" "garage.service"];
      requires = ["garage.service"];
      requisite = ["executor-db-${name}.service"];
      unitConfig.OnFailure = ["executor-db-failed@%n.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = provisionBackup name;
        ExecStart = "${backup name i}/bin/executor-db-${name}-backup";
        TimeoutStartSec = "30min";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    "executor-db-${name}-health" = {
      description = "Check executor database ${name} answers authenticated reads";
      after = ["executor-db-${name}.service"];
      unitConfig.OnFailure = ["executor-db-failed@%n.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${health name i}/bin/executor-db-${name}-health";
        TimeoutStartSec = "1min";
      };
    };
  };
in {
  systemd.slices.executordb = {
    description = "June executor databases (sqld) only";
    sliceConfig = {
      # The sum of the instances' container limits (instances.nix) and a
      # little more; hard, without swap.
      MemoryMax = "448M";
      MemoryHigh = "448M";
      MemorySwapMax = "0";
      CPUQuota = "100%";
      CPUWeight = 50;
      IOWeight = 50;
    };
  };

  systemd.tmpfiles.rules = ["d ${stateDir}/executor-db 0700 root root -"];

  environment.systemPackages = [token convexEnv];

  systemd.services =
    lib.concatMapAttrs instanceServices instances
    // {"executor-db-failed@" = failureAlert;};

  systemd.timers =
    lib.concatMapAttrs (name: _: {
      "executor-db-${name}-backup" = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-* 03:15";
          RandomizedDelaySec = "15min";
          Persistent = true;
        };
      };
      "executor-db-${name}-health" = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "5min";
        };
      };
    })
    instances;
}
