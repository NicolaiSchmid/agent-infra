# The off-host product Borg repository (Hetzner Storage Box #692297), shared by
# Black's append-only writer (hosts/black/storage-box-target.nix) and Forge's
# retention job (hosts/forge/product-backup-retention.nix). The host key was
# verified against Hetzner's published fingerprint on 2026-11-04.
{
  repository = "ssh://u710483@u710483.your-storagebox.de:23/./product-backup/repo";
  knownHosts = "# u710483.your-storagebox.de:23 SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
[u710483.your-storagebox.de]:23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs";
}
