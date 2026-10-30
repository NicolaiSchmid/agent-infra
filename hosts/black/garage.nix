# Garage, a single-node S3 store, for the Convex deployments' files and
# backups (garage/compose.yaml). Never on Traefik: the backends reach it on
# the `garage` docker network, the host on 127.0.0.1. Its RPC secret and
# admin/metrics tokens are generated once into secrets/garage.env.
{stateDir}: {
  config,
  pkgs,
  ...
}: let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  dataDir = "${stateDir}/garage";
  secretsFile = "${stateDir}/secrets/garage.env";
  compose = "${docker} compose --project-directory ${dataDir} -f ${./garage/compose.yaml}";
in {
  systemd.services.garage = {
    description = "Garage S3 for the client-data demo";
    wantedBy = ["multi-user.target"];
    after = ["docker.service"];
    requires = ["docker.service"];
    reloadIfChanged = true;
    environment = {
      GARAGE_CONFIG = "${./garage/garage.toml}";
      GARAGE_DATA_DIR = dataDir;
      GARAGE_SECRETS_FILE = secretsFile;
    };
    path = [config.virtualisation.docker.package pkgs.openssl pkgs.coreutils];
    preStart = ''
      docker network inspect garage >/dev/null 2>&1 || docker network create garage
      mkdir -p ${dataDir}/meta ${dataDir}/data
      if [ ! -s ${secretsFile} ]; then
        umask 077
        {
          echo "GARAGE_RPC_SECRET=$(openssl rand -hex 32)"
          echo "GARAGE_ADMIN_TOKEN=$(openssl rand -base64 32)"
          echo "GARAGE_METRICS_TOKEN=$(openssl rand -base64 32)"
        } > ${secretsFile}.tmp
        mv ${secretsFile}.tmp ${secretsFile}
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${compose} up -d --wait --remove-orphans";
      ExecReload = "${compose} up -d --wait --remove-orphans";
      ExecStop = "${compose} down";
    };
  };
}
