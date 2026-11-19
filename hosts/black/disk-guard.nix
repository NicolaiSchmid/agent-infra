# Free-space check for black's root btrfs, every five minutes.
#
# The atlas images, June production's Convex, Garage and E2B share this one
# filesystem. When it filled on 2026-11-17 and 2026-11-18, June production
# went down each time: the Convex committer stopped on ENOSPC, and a
# `nixos-rebuild switch` on a full disk left a stale Traefik endpoint behind
# (apis.junepartner.com answered TLS and then nothing). Nothing reported the
# shrinking space beforehand. Below `warnGiB` this logs a warning; below
# `failGiB` it logs an error and the unit fails, so `systemctl --failed` and
# the journal show it. It reports; it does not delete anything.
# Runbook: runbooks/atlas-state-shrink.md.
{pkgs, ...}: let
  warnGiB = 60;
  failGiB = 25;
in {
  systemd.services.black-disk-guard = {
    description = "Check free space on black's root filesystem";
    path = [pkgs.coreutils];
    serviceConfig.Type = "oneshot";
    script = ''
      avail=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
      if [ "$avail" -lt ${toString failGiB} ]; then
        echo "<3>black root has ''${avail}G free, below ${toString failGiB}G: June production stops when it fills (runbooks/atlas-state-shrink.md)"
        exit 1
      elif [ "$avail" -lt ${toString warnGiB} ]; then
        echo "<4>black root has ''${avail}G free, below ${toString warnGiB}G"
      else
        echo "black root has ''${avail}G free"
      fi
    '';
  };

  systemd.timers.black-disk-guard = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
    };
  };
}
