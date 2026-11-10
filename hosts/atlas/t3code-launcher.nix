{pkgs, lib, ...}: let
  # Bootstrap/launcher pin only. Server versions selected by the in-app updater
  # live in runtime/service-state.json and must survive rebuilds and reboots.
  version = "0.1.0";
  archive = pkgs.fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/t3-${version}-linux-x64.tar.gz";
    hash = "sha256-93A/8buPYkNYAFizzPLAKrti66S5keJrux2iL0tW2bE=";
  };
  runtime = pkgs.runCommand "t3code-launcher-${version}" {
    nativeBuildInputs = [pkgs.gnutar pkgs.gzip];
  } ''
    mkdir -p "$out"
    tar -xf ${archive} -C "$out" --strip-components=1
    test -x "$out/t3"
    printf '%s\n' ${lib.escapeShellArg version} > "$out/.install-complete"
  '';
in {
  systemd.services.t3code = {
    environment = {
      T3CODE_MODE = "web";
      T3CODE_HOST = "127.0.0.1";
      T3CODE_PORT = "3773";
      T3CODE_NO_BROWSER = "true";
    };
    serviceConfig = {
      WorkingDirectory = "/srv/agents-state/workspace";
      ExecStartPre = lib.mkForce (pkgs.writeShellScript "t3code-bootstrap" ''
        export PATH=${lib.makeBinPath [pkgs.coreutils]}:$PATH
        exec ${pkgs.bash}/bin/bash ${./t3code-bootstrap.sh} \
          /srv/agents-state/t3code ${runtime} ${lib.escapeShellArg version}
      '');
      # Run the executable directly: the launcher needs IPC with its server
      # child and must receive systemd's stop signal before that child does.
      ExecStart = lib.mkForce "${runtime}/t3 __service-launcher";
      KillMode = "mixed";
      TimeoutStopSec = 90;
      Restart = lib.mkForce "always";
    };
  };
}
