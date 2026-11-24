# The account is the parent login; its Black writer key has an exact-repository
# append-only forced command. Retention authority (prune/compact) lives on Forge
# (hosts/forge/product-backup-retention.nix), never on Black.
let
  target = import ../storage-box-repository.nix;
in {
  services.productBackup = {
    enable = true;
    inherit (target) repository knownHosts;
    publicRecipient = builtins.readFile ./storage-box-recipient.pub;
  };
}
