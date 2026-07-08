# Bootstrap

The Hetzner machine boots into rescue at `65.109.71.108`.

1. Verify disks and network:

   ```bash
   ssh -o UserKnownHostsFile=/tmp/black-rescue-known_hosts root@65.109.71.108 \
     'lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL; ip -brief addr'
   ```

2. Install NixOS onto `black`:

   ```bash
   nix run github:nix-community/nixos-anywhere -- \
     --flake .#black \
     --ssh-option UserKnownHostsFile=/tmp/black-rescue-known_hosts \
     root@65.109.71.108
   ```

   If the first boot is unreachable, reboot into rescue and rerun the same
   command. The config forces legacy `eth0` naming and uses removable EFI
   fallback boot paths, so rescue installs do not depend on EFI variable writes.

3. After reboot:

   ```bash
   ssh -i ~/.ssh/agent/black_admin root@65.109.71.108
   ```

4. Define/start the atlas libvirt domain:

   ```bash
   systemctl status atlas-libvirt-domain
   virsh list --all
   ```

5. Build and install the initial `atlas` VM images on `black`:

   ```bash
   nix run github:NicolaiSchmid/agent-infra#install-atlas -- \
     --replace-root \
     --replace-state \
     --start
   ```

   `--replace-state` initializes `/var/lib/libvirt/images/atlas-state.raw`.
   Do not use it after migrated agent state exists.

6. Rebuild `black` after future config changes:

   ```bash
   nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra#black
   ```

7. Rebuild `atlas` after it is reachable:

   ```bash
   nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra#atlas --target-host root@atlas
   ```
