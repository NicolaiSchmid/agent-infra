{
  # Generated locally at ~/.ssh/agent/black_admin. This is used for rescue,
  # first boot, and break-glass SSH. Daily access should go through Tailscale.
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILlChdGVwvIxooBEduk47y6/DTcactoYBrVXMB0aPlOE nicolai@black-admin";

  # Hermes (the assistant called Domovoi) container -> Atlas SSH. The key's
  # historical `hermes@domovoi` comment is only a label, not a hostname.
  hermes = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJWQiNS62UPRvbxNfkM0EzQIagNMOFFa9tzH0OOgSJEv hermes@domovoi";
}
