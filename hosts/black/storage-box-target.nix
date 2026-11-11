# The account is the parent login; its Black writer key has an exact-repository
# forced command. Retention authority belongs to the operator Mac.
{
  services.productBackup = {
    enable = true;
    repository = "ssh://u710483@u710483.your-storagebox.de:23/./product-backup/repo";
    publicRecipient = builtins.readFile ./storage-box-recipient.pub;
    knownHosts = "# u710483.your-storagebox.de:23 SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.20
[u710483.your-storagebox.de]:23 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs";
    # User key alone cannot deliver Pushover messages; no app was authorized.
    pushover.enable = false;
  };
}
