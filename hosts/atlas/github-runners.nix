# Persistent x86_64 Linux GitHub Actions runners for Nicolai's repositories.
#
# One runner per repository, each as a sandboxed systemd service (NixOS
# services.github-runners): own static user, ProtectSystem=strict, PrivateUsers,
# no Docker socket. A job can only write its own work dir and tool cache under
# /srv/agents-state/github-runners/; it cannot reach t3code, Hermes or the
# agents' credentials. Labels: self-hosted, Linux, X64, atlas.
#
# Registration uses the GitHub token in /srv/agents-state/secrets/github-runner.token
# (an access token with `repo` scope; the runner exchanges it for a registration
# token itself, so config changes re-register without manual steps).
{
  config,
  pkgs,
  lib,
  inputs,
  ...
}: let
  # Runner from a newer nixpkgs (see flake.nix, nixpkgs-runner).
  runnerPackage = inputs.nixpkgs-runner.legacyPackages.${pkgs.stdenv.hostPlatform.system}.github-runner;
  owner = "NicolaiSchmid";
  # attribute name -> repository (attribute names are used in runner/user names)
  repos = {
    june = "june";
    fifthset = "fifthset";
    mietprofi = "mietprofi";
    mosaic = "mosaic";
    steno = "steno";
    nicolaischmid-de = "nicolaischmid.de";
  };
  baseDir = "/srv/agents-state/github-runners";
  tokenFile = "/srv/agents-state/secrets/github-runner.token";
  group = "github-runners";
  userOf = name: "ghr-${name}";
  workDirOf = name: "${baseDir}/${name}/work";
  toolCacheOf = name: "${baseDir}/${name}/toolcache";
  # What the GitHub-hosted ubuntu image provides without a setup step and what
  # these repositories' workflows call directly.
  toolchain = with pkgs; [
    nodejs_24
    yarn
    pnpm
    gh
    jq
    curl
    wget
    python3
    gcc
    gnumake
    pkg-config
    unzip
    zip
    rsync
    which
    gnused
    gawk
    gnugrep
    findutils
    openssh
    cacert
  ];
  mkRunner = name: repo: {
    enable = true;
    package = runnerPackage;
    url = "https://github.com/${owner}/${repo}";
    name = "atlas-linux-${name}";
    tokenFile = tokenFile;
    replace = true;
    ephemeral = false;
    extraLabels = ["atlas"];
    user = userOf name;
    group = group;
    workDir = workDirOf name;
    extraPackages = toolchain;
    extraEnvironment = {
      # Keep actions/setup-* downloads across service restarts (workDir is
      # wiped on every start).
      RUNNER_TOOL_CACHE = toolCacheOf name;
      # Prebuilt npm binaries (esbuild, sharp, hermesc, …) need the nix-ld
      # loader; the sandbox does not inherit /etc/profile.
      NIX_LD = config.environment.variables.NIX_LD or "";
      NIX_LD_LIBRARY_PATH = config.environment.variables.NIX_LD_LIBRARY_PATH or "";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
    serviceOverrides = {
      BindPaths = [(toolCacheOf name)];
      # Protect t3code/Hermes on the same VM from a runaway job.
      MemoryHigh = "10G";
      MemoryMax = "12G";
      # The module sets Restart=no (it relies on RestartForceExitStatus=2); we
      # want a crashed listener back without manual intervention.
      Restart = lib.mkForce "on-failure";
      RestartSec = 10;
    };
  };
in {
  services.github-runners = lib.mapAttrs mkRunner repos;

  users.groups.${group} = {};
  users.users = lib.mapAttrs' (name: _:
    lib.nameValuePair (userOf name) {
      isSystemUser = true;
      group = group;
      home = "${baseDir}/${name}";
      createHome = false;
    })
  repos;

  systemd.tmpfiles.rules =
    ["d ${baseDir} 0755 root root -"]
    ++ lib.concatLists (lib.mapAttrsToList (name: _: [
        "d ${baseDir}/${name} 0750 ${userOf name} ${group} -"
        "d ${workDirOf name} 0750 ${userOf name} ${group} -"
        "d ${toolCacheOf name} 0750 ${userOf name} ${group} -"
      ])
      repos);
}
