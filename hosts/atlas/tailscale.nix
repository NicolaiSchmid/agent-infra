{
  config,
  lib,
  ...
}: {
  services.tailscale = {
    enable = true;
    authKeyFile = lib.mkIf (config.sops.secrets ? "tailscale/atlas-authkey") config.sops.secrets."tailscale/atlas-authkey".path;
    port = 41641;
    extraUpFlags = [
      "--ssh"
      "--hostname=atlas"
      "--operator=nicolai"
    ];
  };
}
