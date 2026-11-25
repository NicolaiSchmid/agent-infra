{pkgs, ...}: let
  reclaim = pkgs.writeShellApplication {
    name = "atlas-vm-reclaim";
    runtimeInputs = with pkgs; [coreutils util-linux btrfs-progs e2fsprogs gawk];
    text = builtins.readFile ./vm-reclaim.sh;
  };
in {
  systemd.services.atlas-vm-reclaim = {
    description = "Reclaim partially used Btrfs extents in exclusive Atlas VM images";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${reclaim}/bin/atlas-vm-reclaim";
      StateDirectory = "atlas-vm-reclaim";
      TimeoutStartSec = "30min";
      Nice = 19;
      CPUWeight = 10;
      IOWeight = 10;
      IOSchedulingClass = "idle";
      IOReadBandwidthMax = ["/dev/nvme0n1 40M" "/dev/nvme1n1 40M"];
      IOWriteBandwidthMax = ["/dev/nvme0n1 40M" "/dev/nvme1n1 40M"];
      MemoryHigh = "512M";
      MemoryMax = "1G";
    };
  };
  systemd.timers.atlas-vm-reclaim = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitInactiveSec = "5min";
      AccuracySec = "1min";
    };
  };
}
