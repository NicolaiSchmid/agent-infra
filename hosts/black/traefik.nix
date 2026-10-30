# Traefik on black: TLS on 80/443 for the public Convex origins, plus
# tailnet-only entrypoints for the admin routes (traefik/compose.yaml).
# Creates the traefik-public network the routed containers join.
{stateDir}: {config, ...}: let
  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose --project-directory ${stateDir}/traefik -f ${./traefik/compose.yaml} --env-file ${./traefik/black.env}";
in {
  # Docker's published ports bypass the INPUT chain over IPv4; IPv6 goes
  # through docker-proxy and needs these. 3210/6791 answer only the tailnet
  # (tailnet-only middleware), and tailscale0 is trusted anyway.
  networking.firewall.allowedTCPPorts = [80 443];

  systemd.tmpfiles.rules = ["d ${stateDir}/traefik 0700 root root -"];

  systemd.services.traefik = {
    description = "Traefik for the client-data demo";
    wantedBy = ["multi-user.target"];
    after = ["docker.service" "tailscaled.service"];
    requires = ["docker.service"];
    reloadIfChanged = true;
    environment.TRAEFIK_DYNAMIC_DIR = "${./traefik/dynamic}";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "-${docker} network create traefik-public";
      ExecStart = "${compose} up -d --wait --remove-orphans";
      ExecReload = "${compose} up -d --wait --remove-orphans";
      ExecStop = "${compose} down";
    };
  };
}
