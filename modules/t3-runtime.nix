# Nix owns the protocol-3 launcher; T3 owns the selected child runtime.
# Nightly also supports protocol 3. Keeping the manager independent of the
# child avoids upstream protocol-4 unit reconciliation rewriting Nix units.
{pkgs, version ? "0.1.9", baseDir}: let
  lib = pkgs.lib;
  platform = if pkgs.stdenv.hostPlatform.isDarwin then "darwin-arm64" else "linux-x64";
  releases = {
    "0.1.9" = {
      linux-x64 = "sha256-AUECUzXaM0dZzs2Ns0g+CXcvNgDKA2dGmFJOfZQpE2I=";
      darwin-arm64 = "sha256-fS64wGh7cMoDqdNUmDgYUtN5KYNYnoLR+xgxwI8LIwE=";
    };
    "0.1.10-nightly.20261116.4787" = {
      linux-x64 = "sha256-LJOlSHtc2Cl5JSH2Dk5J+gYSwbeTDNxfLJDnfvnF2hY=";
      darwin-arm64 = "sha256-QRj18ByAOwjzHis8InVdCM0yJgdtD8g0zswdIpPno04=";
    };
  };
  unpack = release: pkgs.runCommand "t3-runtime-${release}-${platform}" {
    nativeBuildInputs = [pkgs.gnutar pkgs.gzip];
    src = pkgs.fetchurl {
      url = "https://github.com/pingdotgg/t3code/releases/download/v${release}/t3-${release}-${platform}.tar.gz";
      hash = releases.${release}.${platform};
    };
  } ''
    mkdir -p "$out"
    tar -xf "$src" -C "$out" --strip-components=1
    test -x "$out/t3"
    printf '%s\n' ${lib.escapeShellArg release} > "$out/.install-complete"
  '';
  launcher = unpack "0.1.9";
  runtime = unpack version;
in {
  inherit launcher runtime;
  bootstrap = pkgs.writeShellScript "t3code-bootstrap" ''
    export PATH=${lib.makeBinPath [pkgs.coreutils pkgs.jq]}:$PATH
    exec ${pkgs.bash}/bin/bash ${./t3-bootstrap.sh} \
      ${lib.escapeShellArg baseDir} ${runtime} ${lib.escapeShellArg version}
  '';
  command = "${launcher}/t3 __service-launcher";
}
