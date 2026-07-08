{
  disko.devices = {
    disk = {
      root = {
        type = "disk";
        device = "/dev/vda";
        imageName = "atlas-root";
        imageSize = "120G";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "1M";
              type = "EF02";
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      state = {
        type = "disk";
        device = "/dev/vdb";
        imageName = "atlas-state";
        imageSize = "650G";
        content = {
          type = "gpt";
          partitions = {
            agents-state = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/srv/agents-state";
              };
            };
          };
        };
      };
    };
  };
}
