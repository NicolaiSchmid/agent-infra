# Daily cleanup of what CI and agents' test stacks leave in Docker: on
# 2026-10-17 they pulled ~15 GB of images and left ~80 anonymous volumes
# within an hour. Removes only
# - anonymous volumes no container (running or stopped) uses,
# - images no container uses that were pulled or built here more than 24h
#   ago (with the containerd image store, `until` is the local record's
#   date, not the image's build date),
# - build cache unused for 24h.
# Named volumes are never touched, nor are stopped containers or anything
# they reference. NixOS's virtualisation.docker.autoPrune runs
# `docker system prune`, which also removes stopped containers; hence this.
{
  config,
  pkgs,
  ...
}: let
  docker = config.virtualisation.docker.package;
  prune = pkgs.writeShellApplication {
    name = "atlas-docker-prune";
    runtimeInputs = [docker pkgs.systemd];
    text = ''
      # hermes runs with --rm: while it is down its image counts as unused,
      # and rebuilding it takes long. Skip the image prune then. Its base
      # images and build cache do go, so the next hermes restart rebuilds
      # from scratch.
      docker volume prune --force
      if systemctl is-active --quiet hermes; then
        docker image prune --all --force --filter until=24h
      else
        echo "hermes is not running, keeping images"
      fi
      docker builder prune --force --filter until=24h
      docker system df
    '';
  };
in {
  systemd.services.atlas-docker-prune = {
    description = "Remove unused Docker volumes, images and build cache";
    # Requisite, not Requires: never start Docker for a prune (e.g. while it
    # is stopped to move its data).
    after = ["docker.service"];
    requisite = ["docker.service"];
    serviceConfig = {
      Type = "oneshot";
      # dockerd does the deleting, in docker.service's cgroup; Nice or an I/O
      # class here would only apply to the CLI.
      ExecStart = "${prune}/bin/atlas-docker-prune";
    };
  };

  systemd.timers.atlas-docker-prune = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*-*-* 04:40";
      RandomizedDelaySec = "10min";
      Persistent = true;
    };
  };
}
