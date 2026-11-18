# The agent-source toolchain: one eve-deployments revision with its
# node_modules (`npm ci --ignore-scripts` from the lockfile) and its pinned
# model catalog (src/agent-source/model-catalog.json, part of the source).
# The builder hashes this tree into every build's toolchain identity, so it is
# installed exactly as eve-deployments documents it: no shebang patching, no
# `npm rebuild`, no fixup.
#
# The source is private: requireFile only names its NAR hash, and the
# operator adds the tree to the store (runbooks/black-agent-source.md).
{
  pkgs,
  pin,
}: let
  name = "eve-deployments-${builtins.substring 0 12 pin.revision}";
  source = pkgs.requireFile {
    inherit name;
    hash = pin.sourceHash;
    hashMode = "recursive";
    message = ''
      ${name} is not in the Nix store. Add `git archive ${pin.revision}`
      as described in runbooks/black-agent-source.md, "Provision the toolchain".
    '';
  };
  npmDeps = pkgs.fetchNpmDeps {
    name = "${name}-npm-deps";
    src = source;
    hash = pin.npmDepsHash;
  };
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "agent-source-toolchain";
    version = builtins.substring 0 12 pin.revision;
    src = source;
    nativeBuildInputs = [pkgs.nodejs_24 pkgs.prefetch-npm-deps];
    dontConfigure = true;
    dontFixup = true;
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      cp -r ${npmDeps} "$TMPDIR/cache"
      chmod -R u+w "$TMPDIR/cache"
      # What nixpkgs' npmConfigHook does before `npm ci`, minus the lockfile
      # rewrite: the lockfile is part of the toolchain identity.
      CACHE_MAP_PATH="$TMPDIR/cache-map" npmDeps=${npmDeps} prefetch-npm-deps --map-cache
      npm_config_cache="$TMPDIR/cache" npm_config_offline=true \
        npm ci --ignore-scripts --no-audit --no-fund
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r . "$out"
      runHook postInstall
    '';
  }
