# Self-hosted Convex deployments on black (demo; see client-data.nix).
# Adding a deployment is one entry in convex/deployments.nix, plus its DNS
# records (runbooks/black-client-data-demo.md).
#
# Per deployment <name>, from the template convex/compose.yaml:
# - backend in compose project convex-<name>: SQLite in <stateDir>/convex/<name>,
#   files/modules/search/exports/imports in Garage buckets <name>-*, public
#   on https://<name>.<baseDomain> (API, WebSocket) and
#   https://<name>-site.<baseDomain> (HTTP actions) through Traefik;
# - secrets/convex-<name>.env (instance secret, Garage key; root, 0600),
#   written once by convex-provision, and secrets/convex-<name>-admin-key,
#   derived from the instance secret on first start;
# - convex-<name>-backup.timer: a daily snapshot export (with file storage)
#   into the Garage bucket <name>-backups, newest 14 kept.
# Shared: one dashboard (convex/dashboard.yaml, tailnet-only) behind the
# portal (convex/portal.mjs: passkey login, deployment list, dashboards with
# the admin key applied; `convex-portal-enroll` adds a passkey), and Garage
# (garage.nix).
{stateDir}: {
  config,
  pkgs,
  lib,
  ...
}: let
  # The deployments and their domain live in convex/deployments.nix, which
  # routes.nix reads too.
  inherit (import ./convex/deployments.nix) baseDomain deployments;
  # The dashboard's own tailnet node (convex/dashboard.yaml), not black's
  # name, so it keeps its address when the stack moves.
  tailnetHost = "convex.takaya-buri.ts.net";

  docker = "${config.virtualisation.docker.package}/bin/docker";
  secrets = "${stateDir}/secrets";
  buckets = ["files" "modules" "search" "exports" "snapshot-imports" "backups"];

  dataDir = name: "${stateDir}/convex/${name}";
  secretsFile = name: "${secrets}/convex-${name}.env";
  adminKeyFile = name: "${secrets}/convex-${name}-admin-key";
  envFile = name: d:
    pkgs.writeText "convex-${name}.env" ''
      CONVEX_NAME=${name}
      CONVEX_CLOUD_HOST=${name}.${baseDomain}
      CONVEX_SITE_HOST=${name}-site.${baseDomain}
      CONVEX_CLOUD_PORT=${toString d.cloudPort}
      CONVEX_SITE_PORT=${toString d.sitePort}
      CONVEX_DATA_DIR=${dataDir name}
      CONVEX_SECRETS_FILE=${secretsFile name}
      CONVEX_MEMORY=${d.memory}
      CONVEX_CPUS=${d.cpus}
    '';
  compose = name: d: "${docker} compose -p convex-${name} --project-directory ${dataDir name} -f ${./convex/compose.yaml} --env-file ${envFile name d}";
  # The portal's mounts, generated: the script, its config, every admin key.
  portalDir = "${stateDir}/convex/portal";
  portalConfig = pkgs.writeText "convex-portal.json" (builtins.toJSON {
    origin = "https://${tailnetHost}";
    rpId = tailnetHost;
    deployments =
      lib.mapAttrsToList (name: _: {
        inherit name;
        url = "https://${name}.${baseDomain}";
      })
      deployments;
  });
  bind = source: target: {
    type = "bind";
    inherit source target;
    read_only = true;
    # Fail instead of creating an empty directory when a key file is missing.
    bind.create_host_path = false;
  };
  portalCompose = pkgs.writeText "convex-portal-compose.json" (builtins.toJSON {
    services.portal.volumes =
      [
        (bind "${./convex/portal.mjs}" "/app/portal.mjs")
        (bind "${portalConfig}" "/app/config.json")
      ]
      ++ lib.mapAttrsToList (name: _: bind (adminKeyFile name) "/keys/${name}") deployments;
    services.tailscale.volumes = [(bind "${serveConfig}" "/config/serve.json")];
  });
  # Tailscale serve: HTTPS on the node, plain HTTP to Traefik.
  serveConfig = pkgs.writeText "convex-serve.json" (builtins.toJSON {
    TCP."443".HTTPS = true;
    Web."\${TS_CERT_DOMAIN}:443".Handlers."/".Proxy = "http://traefik:6792";
  });
  dashboardCompose = "${docker} compose --project-directory ${stateDir}/convex -f ${./convex/dashboard.yaml} -f ${portalCompose}";

  # A one-time link (15 minutes) to add a passkey to the portal.
  enroll = pkgs.writeShellApplication {
    name = "convex-portal-enroll";
    runtimeInputs = with pkgs; [openssl coreutils];
    text = ''
      token=$(openssl rand -hex 32)
      hash=$(printf %s "$token" | openssl dgst -sha256 -binary | basenc --base64url | tr -d =)
      umask 077
      printf '{"hash":"%s","expires":%s}\n' "$hash" "$(( $(date +%s) + 900 ))" > ${portalDir}/enroll.json.tmp
      mv ${portalDir}/enroll.json.tmp ${portalDir}/enroll.json
      echo "Open within 15 minutes, on the device that should hold the passkey:"
      echo "https://${tailnetHost}/_portal/enroll#$token"
    '';
  };

  # Garage: layout once, then per deployment its buckets, its key with access
  # to only those buckets, and its secrets file. Idempotent.
  provision = pkgs.writeShellApplication {
    name = "convex-provision";
    runtimeInputs = [config.virtualisation.docker.package pkgs.openssl pkgs.gawk pkgs.coreutils pkgs.gnugrep];
    text = ''
      g() { docker exec garage /garage "$@"; }
      if g status | grep -q 'NO ROLE ASSIGNED'; then
        node=$(g node id -q | cut -d@ -f1)
        g layout assign -z black -c 50G "$node"
        g layout apply --version 1
      fi
      for name in ${lib.concatStringsSep " " (lib.attrNames deployments)}; do
        for b in ${lib.concatStringsSep " " buckets}; do
          g bucket info "$name-$b" >/dev/null 2>&1 || g bucket create "$name-$b"
        done
        g key info "convex-$name" >/dev/null 2>&1 || g key create "convex-$name" >/dev/null
        for b in ${lib.concatStringsSep " " buckets}; do
          g bucket allow --read --write --owner "$name-$b" --key "convex-$name" >/dev/null
        done
        file=${secrets}/convex-$name.env
        if [ ! -s "$file" ]; then
          umask 077
          info=$(g key info "convex-$name" --show-secret)
          {
            echo "INSTANCE_SECRET=$(openssl rand -hex 32)"
            echo "AWS_ACCESS_KEY_ID=$(awk '/^Key ID:/ {print $3}' <<<"$info")"
            echo "AWS_SECRET_ACCESS_KEY=$(awk '/^Secret key:/ {print $3}' <<<"$info")"
          } > "$file.tmp"
          mv "$file.tmp" "$file"
        fi
      done
    '';
  };

  backup = name: d:
    pkgs.writeShellApplication {
      name = "convex-${name}-backup";
      runtimeInputs = with pkgs; [curl jq rclone coreutils gawk];
      text = ''
        url=http://127.0.0.1:${toString d.cloudPort}
        auth="Authorization: Convex $(cat ${adminKeyFile name})"
        set -a
        # shellcheck source=/dev/null
        . ${secretsFile name}
        set +a
        export RCLONE_CONFIG_GARAGE_TYPE=s3 RCLONE_CONFIG_GARAGE_PROVIDER=Other \
          RCLONE_CONFIG_GARAGE_ENDPOINT=http://127.0.0.1:3900 RCLONE_CONFIG_GARAGE_REGION=garage \
          RCLONE_CONFIG_GARAGE_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
          RCLONE_CONFIG_GARAGE_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
        dest=garage:${name}-backups/daily

        # What `npx convex export --include-file-storage` does: request a
        # snapshot export, wait for it, download the zip.
        curl -fsS -X POST -H "$auth" "$url/api/export/request/zip?includeStorage=true" >/dev/null
        for _ in $(seq 360); do
          latest=$(curl -fsS -X POST -H "$auth" -H 'content-type: application/json' \
            -d '{"path":"_system/cli/exports:getLatest","args":{},"format":"json"}' "$url/api/query")
          state=$(jq -r .value.state <<<"$latest")
          [ "$state" = completed ] && break
          [ "$state" = failed ] && { echo "export failed" >&2; exit 1; }
          sleep 5
        done
        [ "$state" = completed ] || { echo "export still $state after 30 min" >&2; exit 1; }
        ts=$(jq -r .value.start_ts <<<"$latest")
        zip=$(mktemp --suffix=.zip)
        trap 'rm -f "$zip"' EXIT
        curl -fsS -H "$auth" "$url/api/export/zip/$ts" -o "$zip"
        rclone copyto "$zip" "$dest/$(date -u +%Y-%m-%dT%H%M%SZ)-$ts.zip"
        echo "exported $(stat -c %s "$zip") bytes at $ts"

        # Keep the newest 14.
        rclone lsf "$dest" | sort | head -n -14 | while read -r old; do
          rclone deletefile "$dest/$old"
          echo "removed $old"
        done
      '';
    };

  deploymentServices = name: d: {
    "convex-${name}" = {
      description = "Self-hosted Convex ${name} (demo, no client data)";
      wantedBy = ["multi-user.target"];
      after = ["docker.service" "convex-provision.service" "traefik.service"];
      requires = ["docker.service"];
      wants = ["convex-provision.service" "traefik.service"];
      reloadIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "15min";
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${dataDir name}";
        ExecStart = "${compose name d} up -d --wait --remove-orphans";
        ExecReload = "${compose name d} up -d --wait --remove-orphans";
        ExecStartPost = pkgs.writeShellScript "convex-${name}-admin-key" ''
          set -eu
          [ -s ${adminKeyFile name} ] && exit 0
          umask 077
          # The script prints a label line, then the key.
          ${compose name d} exec -T backend ./generate_admin_key.sh | tail -n 1 > ${adminKeyFile name}.tmp
          mv ${adminKeyFile name}.tmp ${adminKeyFile name}
          # The portal mounts every admin key, so it can only list a new
          # deployment once the key exists; its reload in the same switch ran
          # before. Fails harmlessly until every new deployment has its key.
          ${config.systemd.package}/bin/systemctl reload --no-block convex-dashboard.service || true
        '';
        ExecStop = "${compose name d} down";
      };
    };

    "convex-${name}-backup" = {
      description = "Back up Convex ${name} into Garage";
      after = ["convex-${name}.service"];
      requisite = ["convex-${name}.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backup name d}/bin/convex-${name}-backup";
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };
  };
in {
  systemd.tmpfiles.rules = [
    "d ${stateDir}/convex 0700 root root -"
    "d ${portalDir} 0700 root root -"
    "d ${stateDir}/convex/tailscale 0700 root root -"
  ];

  environment.systemPackages = [enroll];

  systemd.services =
    lib.concatMapAttrs deploymentServices deployments
    // {
      convex-provision = {
        description = "Garage buckets, keys and secrets for the Convex deployments";
        after = ["garage.service"];
        requires = ["garage.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${provision}/bin/convex-provision";
        };
      };

      convex-dashboard = {
        description = "Convex dashboard and portal for every deployment (tailnet-only)";
        wantedBy = ["multi-user.target"];
        # After the deployments: the portal mounts their admin keys, written
        # on each one's first start.
        after = ["docker.service" "traefik.service"] ++ map (name: "convex-${name}.service") (lib.attrNames deployments);
        requires = ["docker.service"];
        wants = ["traefik.service"] ++ map (name: "convex-${name}.service") (lib.attrNames deployments);
        reloadIfChanged = true;
        environment = {
          TAILNET_HOST = tailnetHost;
          PORTAL_STATE_DIR = portalDir;
          TAILSCALE_STATE_DIR = "${stateDir}/convex/tailscale";
          TAILSCALE_AUTHKEY_FILE = "${secrets}/convex-tailscale.env";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${dashboardCompose} up -d --wait --remove-orphans";
          ExecReload = "${dashboardCompose} up -d --wait --remove-orphans";
          ExecStop = "${dashboardCompose} down";
        };
      };
    };

  systemd.timers = lib.mapAttrs' (name: _:
    lib.nameValuePair "convex-${name}-backup" {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*-*-* 03:30";
        RandomizedDelaySec = "30min";
        Persistent = true;
      };
    })
  deployments;
}
