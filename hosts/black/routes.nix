# routes-api on black: each project pushes its own Traefik routing table from
# its deploy pipeline (PUT https://<hostname>/v1/projects/<project>/routes,
# routes/main.go), and this file only says what each project may route:
# - hosts: hostnames it may claim, exact or "*.<domain>" for any single
#   label under <domain>; no two projects may claim the same name;
# - convex: deployments (convex/deployments.nix) it may send traffic to,
#   either origin (cloud: API and WebSocket; site: HTTP actions).
# A leaked key can reroute only that project's hostnames, and only to that
# project's targets. Operations: runbooks/black-client-data-demo.md, section
# "Routes API".
#
# One key per project, generated on first start into
# secrets/routes-<project>-key (root, 0600); the container sees only its
# SHA-256 in routes/keys/. The accepted tables live in routes/state/, the
# rendered files (routes-<project>.yml) in Traefik's dynamic directory.
{
  stateDir,
  traefikDynamicDir,
}: {
  config,
  pkgs,
  lib,
  ...
}: let
  hostname = "routes.modusservice.com";

  projects = {
    # NicolaiSchmid/modus, apps/gateway.
    modus-gateway = {
      hosts = ["inference.modusservice.com" "inference-dev.modusservice.com"];
      convex = ["modus-gateway-dev" "modus-gateway-prod"];
    };
    # NicolaiSchmid/modus, apps/site (its Convex project).
    modus = {
      hosts = [];
      convex = ["modus-dev" "modus-prod"];
    };
    # June (NicolaiSchmid/nicoolai) joins with its hostnames, convex =
    # ["june-dev" "june-prod"].
  };

  inherit (import ./convex/deployments.nix) baseDomain deployments;
  # The container's user; owns what it writes.
  uid = 65532;
  dir = "${stateDir}/routes";
  keysDir = "${dir}/keys";

  api = pkgs.runCommand "routes-api" {nativeBuildInputs = [pkgs.nodejs_24];} ''
    cp -r ${./routes} source
    chmod -R u+w source
    node --test source/*.test.ts
    mkdir -p $out/lib $out/bin
    cp source/*.ts source/package.json $out/lib/
    cat > $out/bin/routes-api <<EOF
    #!${pkgs.runtimeShell}
    exec ${pkgs.nodejs_24}/bin/node $out/lib/server.ts "\$@"
    EOF
    chmod +x $out/bin/routes-api
  '';
  image = pkgs.dockerTools.streamLayeredImage {
    name = "routes-api";
    contents = [api];
    config.Entrypoint = ["/bin/routes-api"];
  };

  registry = pkgs.writeText "routes-registry.json" (builtins.toJSON {inherit projects;});
  envFile = pkgs.writeText "routes.env" ''
    ROUTES_IMAGE=${image.imageName}:${image.imageTag}
    ROUTES_UID=${toString uid}
    ROUTES_HOST=${hostname}
    ROUTES_REGISTRY=${registry}
    ROUTES_KEYS_DIR=${keysDir}
    ROUTES_STATE_DIR=${dir}/state
    ROUTES_DYNAMIC_DIR=${traefikDynamicDir}
  '';
  docker = "${config.virtualisation.docker.package}/bin/docker";
  compose = "${docker} compose --project-directory ${dir} -f ${./routes/compose.yaml} --env-file ${envFile}";

  # Keys on first start, their hashes for the container, the image into
  # Docker. Runs before every start and reload. Rotating a key: delete its
  # file, then `systemctl restart routes`.
  prepare = pkgs.writeShellApplication {
    name = "routes-prepare";
    runtimeInputs = [config.virtualisation.docker.package pkgs.openssl pkgs.coreutils];
    text = ''
      rm -f ${keysDir}/*.sha256
      for project in ${lib.concatStringsSep " " (lib.attrNames projects)}; do
        key=${stateDir}/secrets/routes-$project-key
        if [ ! -s "$key" ]; then
          (umask 077; openssl rand -hex 32 > "$key.tmp"; mv "$key.tmp" "$key")
        fi
        hash=$(tr -d '\n' < "$key" | sha256sum | cut -d' ' -f1)
        printf '%s\n' "$hash" > ${keysDir}/"$project".sha256
        chown ${toString uid}:${toString uid} ${keysDir}/"$project".sha256
        chmod 0400 ${keysDir}/"$project".sha256
      done
      ${image} | docker load
    '';
  };

  # Registry checks at evaluation time; the service repeats the basic ones.
  claims = lib.concatLists (lib.mapAttrsToList (project: p: map (host: {inherit project host;}) p.hosts) projects);
  covers = pattern: host:
    pattern
    == host
    || (lib.hasPrefix "*." pattern
      && (let
        suffix = lib.removePrefix "*" pattern;
        label = lib.removeSuffix suffix host;
      in
        lib.hasSuffix suffix host && label != "" && !(lib.hasInfix "." label)));
  overlaps = a: b: a.project != b.project && (covers a.host b.host || covers b.host a.host || a.host == b.host);
  conflicts = lib.filter (a: lib.any (overlaps a) claims) claims;
  reserved = host: host == hostname || lib.hasSuffix ".${baseDomain}" host || host == baseDomain;
in {
  assertions =
    [
      {
        assertion = conflicts == [];
        message = "routes.nix: hostnames claimed by more than one project: ${lib.concatMapStringsSep ", " (c: "${c.host} (${c.project})") conflicts}";
      }
      {
        assertion = !(lib.any (c: reserved c.host) claims);
        message = "routes.nix: ${hostname} and the Convex hosts under ${baseDomain} cannot be claimed by a project.";
      }
      {
        # Traefik's directory belongs to the routes service for these names.
        assertion = !(lib.any (lib.hasPrefix "routes-") (lib.attrNames (builtins.readDir ./traefik/dynamic)));
        message = "traefik/dynamic: file names starting with routes- are reserved for routes-api.";
      }
    ]
    ++ lib.mapAttrsToList (project: p: {
      assertion = lib.all (d: deployments ? ${d}) p.convex;
      message = "routes.nix: project ${project} names a Convex deployment that convex/deployments.nix does not have.";
    })
    projects;

  systemd.tmpfiles.rules = [
    "d ${dir} 0700 root root -"
    "d ${keysDir} 0500 ${toString uid} ${toString uid} -"
    "d ${dir}/state 0700 ${toString uid} ${toString uid} -"
    # Traefik reads it (traefik.nix installs the static files); routes-api
    # writes routes-<project>.yml next to them.
    "d ${traefikDynamicDir} 0755 ${toString uid} ${toString uid} -"
  ];

  systemd.services.routes = {
    description = "routes-api: per-project Traefik routes, pushed by each project";
    wantedBy = ["multi-user.target"];
    after = ["docker.service" "traefik.service"];
    requires = ["docker.service"];
    wants = ["traefik.service"];
    reloadIfChanged = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "${prepare}/bin/routes-prepare";
      ExecStart = "${compose} up -d --wait --remove-orphans";
      ExecReload = ["${prepare}/bin/routes-prepare" "${compose} up -d --wait --remove-orphans"];
      ExecStop = "${compose} down";
    };
  };
}
