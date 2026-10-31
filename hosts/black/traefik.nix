# Traefik on black: TLS on 80/443 for the public Convex origins, plus
# tailnet-only entrypoints for the admin routes (traefik/compose.yaml).
# Creates the traefik-public network the routed containers join.
#
# The file provider reads one directory, traefikDynamicDir, shared by the
# static files in traefik/dynamic/ (installed into it on every start and
# reload) and the routes-<project>.yml files routes-api writes (routes.nix,
# which also creates the directory).
{
  stateDir,
  traefikDynamicDir,
}: {
  config,
  pkgs,
  ...
}: let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose --project-directory ${stateDir}/traefik -f ${./traefik/compose.yaml} --env-file ${./traefik/black.env}";
  # Copy each static file in through a rename (Traefik never sees half a
  # file) and drop static files no longer in the repository; routes-* and
  # their temporary .routes-* files belong to routes-api.
  syncDynamic = pkgs.writeShellScript "traefik-sync-dynamic" ''
    set -eu
    dir=${traefikDynamicDir}
    for f in "$dir"/*; do
      name=''${f##*/}
      case $name in routes-*) continue ;; esac
      [ -e "${./traefik/dynamic}/$name" ] || rm -f "$f"
    done
    for f in ${./traefik/dynamic}/*; do
      name=''${f##*/}
      ${pkgs.coreutils}/bin/install -m 0644 "$f" "$dir/.$name.tmp"
      mv -f "$dir/.$name.tmp" "$dir/$name"
    done
  '';
in {
  # Docker's published ports bypass the INPUT chain over IPv4; IPv6 goes
  # through docker-proxy and needs these.
  networking.firewall.allowedTCPPorts = [80 443];

  systemd.tmpfiles.rules = ["d ${stateDir}/traefik 0700 root root -"];

  systemd.services.traefik = {
    description = "Traefik for the client-data demo";
    wantedBy = ["multi-user.target"];
    after = ["docker.service" "tailscaled.service"];
    requires = ["docker.service"];
    reloadIfChanged = true;
    environment.TRAEFIK_DYNAMIC_DIR = traefikDynamicDir;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = ["-${docker} network create traefik-public" syncDynamic];
      ExecStart = "${compose} up -d --wait --remove-orphans";
      ExecReload = [syncDynamic "${compose} up -d --wait --remove-orphans"];
      ExecStop = "${compose} down";
    };
  };
}
