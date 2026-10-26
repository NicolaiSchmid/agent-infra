# Watches the Forge macOS GitHub Actions runners and flips the per-repository
# MACOS_RUNS_ON variable between Forge and GitHub-hosted macOS runners, so
# macOS jobs prefer Forge but fall back when it is offline. Linux jobs run on
# Ubicloud and are not managed here.
{pkgs, ...}: let
  watchdog = pkgs.writeShellApplication {
    name = "forge-runner-watchdog";
    runtimeInputs = with pkgs; [gh jq coreutils];
    text = builtins.readFile ./forge-runner-watchdog.sh;
  };
in {
  systemd.services.forge-runner-watchdog = {
    description = "Point MACOS_RUNS_ON at the Forge macOS runners when they are online";
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
