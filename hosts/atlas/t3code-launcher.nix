{pkgs, lib, ...}: let
  # Atlas follows the nightly channel, like Forge; the stable launcher
  # (protocol 3) stays compatible with the nightly child runtime.
  t3 = import ../../modules/t3-runtime.nix {
    inherit pkgs;
    baseDir = "/srv/agents-state/t3code";
    version = "0.1.10-nightly.20261116.4787";
  };
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
      ExecStartPre = lib.mkForce t3.bootstrap;
      ExecStart = lib.mkForce t3.command;
      KillMode = "mixed";
      TimeoutStopSec = 90;
      # First adoption copies the ~55 GiB state databases in ExecStartPre.
      TimeoutStartSec = "1h";
      Restart = lib.mkForce "always";
    };
  };
  systemd.services.hermes.serviceConfig.MemoryLow = "1G";
}
