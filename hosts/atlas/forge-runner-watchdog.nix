# Watches the Forge GitHub Actions runners and flips the per-repository
# LINUX_RUNS_ON / MACOS_RUNS_ON variables between Forge and GitHub-hosted
# runners, so workflows prefer Forge but fall back when it is offline.
{pkgs, ...}: let
  watchdog = pkgs.writeShellApplication {
    name = "forge-runner-watchdog";
    runtimeInputs = with pkgs; [gh jq coreutils];
    text = builtins.readFile ./forge-runner-watchdog.sh;
  };
in {
  systemd.services.forge-runner-watchdog = {
    description = "Point GitHub workflow runner variables at Forge when it is online";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "nicolai";
      Group = "users";
      Environment = ["HOME=/srv/agents-state/nicolai"];
      ExecStart = "${watchdog}/bin/forge-runner-watchdog";
    };
  };

  systemd.timers.forge-runner-watchdog = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
      RandomizedDelaySec = "20s";
      Unit = "forge-runner-watchdog.service";
    };
  };
}
