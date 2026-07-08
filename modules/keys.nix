{
  # Generated locally at ~/.ssh/agent/black_admin. This is used for rescue,
  # first boot, and break-glass SSH. Daily access should go through Tailscale.
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILlChdGVwvIxooBEduk47y6/DTcactoYBrVXMB0aPlOE nicolai@black-admin";

  # Hermes container -> atlas SSH. This is already part of the current
  # dotfiles-nix agent config; kept here for the future cleanup pass.
  hermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJWQiNS62UPRvbxNfkM0EzQIagNMOFFa9tzH0OOgSJEv hermes@domovoi";
}
