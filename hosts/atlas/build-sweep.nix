# Hourly removal of stale build output on atlas; see build-sweep.sh.
{pkgs, ...}: let
  sweep = pkgs.writeShellApplication {
    name = "atlas-build-sweep";
    runtimeInputs = with pkgs; [coreutils findutils gnugrep gnused sqlite];
    text = builtins.readFile ./build-sweep.sh;
  };
in {
  systemd.services.atlas-build-sweep = {
    description = "Remove stale build output from agent worktrees and scratch checkouts";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${sweep}/bin/atlas-build-sweep";
      StateDirectory = "atlas-build-sweep";
      # Stay out of the way of t3code and the agents. IOSchedulingClass and
      # IOWeight only take effect with the BFQ scheduler set in priorities.nix.
      Nice = 19;
      IOSchedulingClass = "idle";
      CPUWeight = 10;
      IOWeight = 10;
    };
  };

  systemd.timers.atlas-build-sweep = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*:25";
      AccuracySec = "1min";
      Unit = "atlas-build-sweep.service";
    };
  };
}
