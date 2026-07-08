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

3. After reboot:

   ```bash
   ssh -i ~/.ssh/agent/black_admin root@65.109.71.108
   ```

4. Define/start the atlas libvirt domain:

   ```bash
   systemctl status atlas-libvirt-domain
   virsh list --all
   ```

The first `atlas` OS install still needs an installer path. The intended target
is `nixos-anywhere --flake .#atlas` against the VM once it has temporary SSH
from an installer/rescue image, or building a raw disk image from the flake and
writing it to `atlas-root.raw`.
