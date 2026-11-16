# Boot the existing forge-linux Lima VM as a system daemon. It hosts the
# Prometheus CLIProxyAPI hub (hosts/forge/prometheus), which must come back
# while forge sits at the login window after a reboot. The Linux runners that
# used to live in this VM were retired in #37; this only starts the instance
# that is already there and never provisions a new one.
{pkgs, ...}: let
  username = "nschmid10049";
  homeDir = "/Users/${username}";
  start = pkgs.writeShellScript "forge-linux-start" ''
    set -euo pipefail
    export HOME="${homeDir}"
    if ! ${pkgs.lima}/bin/limactl list --json 2>/dev/null | ${pkgs.jq}/bin/jq -e 'select(.name == "forge-linux")' >/dev/null; then
      echo "forge-linux: no Lima instance; see hosts/forge/prometheus/README.md" >&2
      exit 1
    fi
    exec ${pkgs.lima}/bin/limactl start forge-linux
  '';
in {
  environment.systemPackages = [pkgs.lima];

  launchd.daemons.forge-linux = {
    command = "${start}";
    serviceConfig = {
      UserName = username;
      GroupName = "staff";
      RunAtLoad = true;
      StandardOutPath = "${homeDir}/Library/Logs/forge-linux.log";
      StandardErrorPath = "${homeDir}/Library/Logs/forge-linux.error.log";
    };
  };
}
