# AMD memory encryption on black

Investigated read-only on 2026-11-19. **Nothing changed on black, no reboot,
no Hetzner ticket.** Every step below that touches the BIOS or reboots needs
Nicolai's explicit go and a maintenance window: a reboot interrupts June prod
Convex, the MODUS gateway, the hosted runners and the atlas VM.

Motivation: the June DSFA (`docs/legal/dsfa-unterstuetzung.md`, R6 and the
paragraph on storage) names RAM contents of the running server as the residual
physical risk. Transparent memory encryption narrows that risk.

## Findings (2026-11-19)

| Check | Result |
| --- | --- |
| CPU | AMD Ryzen 7 7700 (Zen 4 "Raphael", non-PRO), microcode `0xa601209` |
| Board / BIOS | ASRock Rack B665D4U-1L, AMI BIOS 20.12 (2025-04-23), UEFI, Secure Boot off |
| Raw CPUID `0x8000001F` | **SME = 1**, SEV = SEV-ES = SEV-SNP = 0, C-bit 51, phys. address reduction 2 |
| `/proc/cpuinfo` flags | no `sme`/`sev` (the kernel hides them unless the BIOS enabled encryption) |
| `address sizes` | `48 bits physical`, so not reduced: the BIOS has **SYSCFG.MemEncryptionModEn (SMEE) off** |
| PSP `tsme_status` (`/sys/bus/pci/devices/0000:0d:00.2/tsme_status`) | **0, so TSME is off** (`fused_part=1`, `debug_lock_on=1`) |
| Kernel | 6.18.38, `CONFIG_AMD_MEM_ENCRYPT=y`, no `..._ACTIVE_BY_DEFAULT`, cmdline without `mem_encrypt` |
| Active? | **No.** No memory encryption of any kind is active |
| IOMMU | AMD-Vi present (`ivhd0`) |
| GPU | `amdgpu` bound to the iGPU, no `/dev/dri` users |
| VMs | `kvm_amd` in use: libvirt guest `atlas`, Firecracker (E2B) |
| **Disks** | **Not encrypted.** btrfs RAID1 directly on `nvme{0,1}n1p2`, no LUKS/dm-crypt, no device-mapper devices, no initrd unlock. `/var` is 92 % full (869 of 953 GB). |

How to re-check (all read-only):

```sh
ssh root@black 'grep -m1 "address sizes" /proc/cpuinfo
  cat /sys/bus/pci/devices/0000:0d:00.2/tsme_status
  nix shell nixpkgs#cpuid -c cpuid -1 -l 0x8000001f | head -8
  dmesg | grep -i "memory encryption"'
```

SME active shows `Memory Encryption Features active: AMD SME` in dmesg and
`address sizes: 46 bits physical`. TSME active shows `tsme_status` = 1 (the
kernel also logs `psp: TSME enabled`). Under TSME alone, the kernel prints
nothing about SME.

## What this means

- **SEV / SEV-ES / SEV-SNP are not available** on this CPU (desktop part).
  Encrypted or attested VMs would need an EPYC server.
- **SME is supported by the silicon but disabled by the BIOS.** Setting
  `mem_encrypt=on` alone does nothing; the BIOS option must be switched first.
- **TSME** (transparent SME) is a memory-controller setting with no OS
  involvement. AMD markets it as "Memory Guard" for Ryzen PRO. Whether the
  ASRock Rack BIOS exposes and honours it on this non-PRO 7700 is
  **unverified**; `tsme_status` after a boot is the proof.

Both modes encrypt DRAM with an AES key that the memory controller generates
anew at each boot and that never leaves the SoC. They protect against DIMM
removal, cold-boot and bus snooping. They do **not** protect against anyone
who reaches the running OS (root, console with credentials), DMA from PCIe
devices (the BMC included), which the memory controller decrypts
transparently and the IOMMU only partly limits, or a compromised kernel.

**Disk encryption is the larger gap.** Without it, anyone with physical access
or Hetzner Robot (rescue system plus hardware reset) can read all data at
rest without touching RAM. Memory encryption only pays off once the disks are
encrypted and their key lives only in RAM. See "DSFA consequences" below.

## Preferred: TSME (BIOS only)

No NixOS change. Encrypts all of DRAM, including memory the kernel would leave
unencrypted under SME (early boot, firmware, swiotlb).

1. Get BIOS access in a maintenance window. Either:
   - request a KVM console (LARA/JavaKVM) in Hetzner Robot for a fixed slot
     and change the setting ourselves, or
   - ask Hetzner support to change it, with an agreed time.
2. Setting (AMI/AGESA naming, may vary): `Advanced → AMD CBS → UMC Common
   Options → DDR Security → TSME = Enabled` (default `Auto` is off on non-PRO).
   Change nothing else.
3. Boot normally. Verify `tsme_status` = 1, all services healthy
   (Convex prod, gateway, routes, atlas VM, hosted runners), and memory
   bandwidth/latency look normal (expected overhead about 1–2 % latency).
4. **Rollback:** set TSME back to `Auto`/`Disabled` via KVM or support. The OS
   is untouched, so a boot failure under TSME is a firmware/memory-training
   problem: KVM console shows it; Hetzner can reset the BIOS (CMOS clear).

If the option is missing or `tsme_status` stays 0, fall back to SME.

## Fallback: SME (BIOS SMEE + `mem_encrypt=on`)

Config prepared in `hosts/black/memory-encryption.nix`: a NixOS specialisation
`sme` that adds `mem_encrypt=on`. It is only an extra GRUB entry, so the
default boot entry stays without it, and while SMEE is off it is a no-op
anyway.

Risks, assessed for this box:

- **Boot failure without console.** The main risk. Mitigated by the one-shot
  boot below and the Hetzner rescue system (disks are unencrypted, so rescue
  can mount and repair directly).
- **amdgpu.** The driver refuses SME only on Raven (2017 APUs); Raphael's
  iGPU is supported. Nothing uses it; if the SME boot logs amdgpu errors, add
  `boot.blacklistedKernelModules = ["amdgpu"]` to the specialisation.
- **DMA / IOMMU.** NVMe and igb have 64-bit DMA masks, so they can address
  the C-bit; others bounce through swiotlb (unencrypted bounce buffers).
  AMD-Vi is present.
- **KVM guests (atlas, Firecracker).** Supported: KVM maps guest memory with
  the host's SME mask. Guests are not isolated from the host (that would be
  SEV, which this CPU lacks).
- **Docker / gVisor / userspace.** Transparent; nothing to change.
- **Performance.** Small: about 1–2 % memory latency, extra swiotlb copies
  only for devices that need bounce buffers.

Steps:

1. Merge and deploy the config (`nixos-rebuild switch --flake
   github:NicolaiSchmid/agent-infra/<rev>#black`). No runtime effect. Check
   that GRUB got the entry:
   `grep -n '(sme' /boot/grub/grub.cfg /boot-fallback/grub/grub.cfg`.
2. In the BIOS window (KVM or support): `Advanced → AMD CBS → CPU Common
   Options → SMEE = Enabled`. Boot the **default** entry first: it should come
   up unchanged except `address sizes: 46 bits physical`. Verify services.
3. One-shot boot into SME. Set `next_entry` on both mirrored ESPs (the
   firmware boots either one) using the exact title from step 1:
   ```sh
   for d in /boot /boot-fallback; do
     grub-editenv "$d/grub/grubenv" set next_entry='NixOS - (sme)'
   done
   systemctl reboot
   ```
   GRUB clears `next_entry` on that boot, so the next reboot returns to the
   default entry. If the box doesn't come back in about 10 minutes, use
   Hetzner Robot → Reset → hardware reset, which boots the default entry.
4. Verify: `dmesg | grep -i "memory encryption"` shows `active: AMD SME`;
   no amdgpu/IOMMU/nvme errors in `journalctl -k -b`; Convex prod, gateway,
   runners and atlas healthy; let it run a day.
5. Make permanent: move `mem_encrypt=on` from the specialisation into black's
   `boot.kernelParams`, remove the specialisation, deploy, reboot once more.
6. **Rollback:** boot an older generation or remove the parameter and
   deploy; or set SMEE back to Disabled. If the box is unreachable: Robot →
   activate rescue system → hardware reset → mount both ESPs
   (`/dev/nvme0n1p1`, `/dev/nvme1n1p1`) and delete `mem_encrypt=on` from
   `grub/grub.cfg` on each (or set `grub-editenv grub/grubenv set
   next_entry=...` to a previous generation's title), deactivate rescue,
   reset. Then deploy a config without the parameter so GRUB is regenerated.

## DSFA consequences (R1, R6, storage paragraph)

As of 2026-11-19 the DSFA says that black's data is on encrypted disks and
that an authorised person must enter the unlock passphrase from outside after
each reboot. **That is not true for black**: there is no disk encryption and
no unlock step. Backups to the Storage Box are encrypted (Borg + age), which
the DSFA states correctly.

Until that changes, the text should say so, or the disks must be encrypted
first (LUKS on both NVMe, initrd SSH unlock via `boot.initrd.network.ssh`,
re-provisioning with data migration; `/var` at 92 % leaves no room to convert
in place). That is a separate, larger project.

With memory encryption active (and disk encryption done), R6 may additionally
claim something like: *"The memory controller transparently encrypts RAM
contents with a key generated anew at each boot that never leaves the
processor (AMD TSME/SME). This protects against removing memory modules and
cold-boot attacks, but not against access through the running operating
system or through DMA-capable devices."* The residual risk narrows; it does
not go away. Without disk encryption, memory encryption does not change the
R6 assessment in substance.
