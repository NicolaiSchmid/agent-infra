{
  disko.devices = {
    disk = {
      nvme0 = {
        type = "disk";
        device = "/dev/nvme0n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "mdraid";
                name = "boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "root";
              };
            };
          };
        };
      };

      nvme1 = {
        type = "disk";
        device = "/dev/nvme1n1";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              content = {
                type = "mdraid";
                name = "boot";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "root";
              };
            };
          };
        };
      };
    };

    mdadm = {
      boot = {
        type = "mdadm";
        level = 1;
        metadata = "1.0";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = ["umask=0077"];
        };
      };

      root = {
        type = "mdadm";
        level = 1;
        content = {
          type = "btrfs";
          extraArgs = [
            "-f"
            "-L"
            "black-root"
          ];
          subvolumes = {
            "/root" = {
              mountpoint = "/";
              mountOptions = [
                "compress=zstd"
                "noatime"
                "ssd"
              ];
            };
            "/nix" = {
              mountpoint = "/nix";
              mountOptions = [
                "compress=zstd"
                "noatime"
                "ssd"
              ];
            };
            "/var" = {
              mountpoint = "/var";
              mountOptions = [
                "compress=zstd"
                "noatime"
                "ssd"
              ];
            };
            "/libvirt-images" = {
              mountpoint = "/var/lib/libvirt/images";
              mountOptions = [
                "noatime"
                "ssd"
              ];
            };
          };
        };
      };
    };
  };
}
