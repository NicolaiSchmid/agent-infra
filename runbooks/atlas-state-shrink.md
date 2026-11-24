# Shrink atlas-state.raw to 550G

`hosts/black/libvirt.nix` declares a 550G state disk (`atlasStateSize`), but
the existing image keeps the size it was created with (750G since
2026-10-25). This runbook shrinks it in place. It needs atlas shut down, so
run it from a shell on black, never from an agent session inside atlas.

Why 550G: black has 953G. Atlas's images (120G root plus state), June
production's Convex, Garage, E2B and Nix all share it. At 750G black filled up
on 2026-11-17 and 2026-11-18 and took June production down with it.
`black-disk-guard` (`hosts/black/disk-guard.nix`) now reports low space.

## Before

- Inside atlas, `df -h /srv/agents-state` shows at most 480G used. The ext4
  filesystem shrinks to 540G first, and resize2fs needs headroom.
- Nothing important is running on atlas. Every agent session ends.
- Note the free space on black: `df -h /`.

## Steps (on black, as root)

```bash
img=/var/lib/libvirt/images/atlas-state.raw
virsh shutdown atlas
until [ "$(virsh domstate atlas)" = "shut off" ]; do sleep 5; done

modprobe nbd max_part=8
qemu-nbd --format=raw --connect=/dev/nbd0 "$img"
e2fsck -f -p /dev/nbd0p1
resize2fs -p /dev/nbd0p1 540G          # minutes to an hour; do not interrupt

# Shrink the partition: same start, GUIDs and name, new size. 550G is
# 1153433600 sectors; 1153429504 leaves room for the backup GPT and keeps
# 1 MiB alignment.
sfdisk --dump /dev/nbd0 > /root/atlas-state-before-shrink.sfdisk
grep -v '^last-lba:' /root/atlas-state-before-shrink.sfdisk |
  sed -E 's/size= *[0-9]+/size=1153429504/' > /root/atlas-state-550g.sfdisk
sfdisk --no-reread /dev/nbd0 < /root/atlas-state-550g.sfdisk
qemu-nbd --disconnect /dev/nbd0

truncate -s 550G "$img"                # frees everything allocated past 550G

qemu-nbd --format=raw --connect=/dev/nbd0 "$img"
sgdisk -e /dev/nbd0                    # move the backup GPT to the new end
sgdisk -v /dev/nbd0                    # "No problems found"
e2fsck -f -p /dev/nbd0p1
resize2fs /dev/nbd0p1                  # grow the filesystem to fill the partition
qemu-nbd --disconnect /dev/nbd0

virsh start atlas
```

## After

- Inside atlas: `lsblk /dev/vdb` shows 550G, and `df -h /srv/agents-state`
  shows the same used space as before.
- On black: `df -h /` and `compsize -x /var/lib/libvirt/images/*.raw`. The
  images take at most 670G plus extent slack. Without trims (`discard='ignore'`),
  that is the most they can ever take.

## If a step fails

- Before `truncate`, nothing is lost: `resize2fs /dev/nbd0p1` without a size
  grows the filesystem back, and `sfdisk /dev/nbd0 < /root/atlas-state-before-shrink.sfdisk`
  restores the partition table.
- After `truncate`, the bytes past 550G are gone. If e2fsck reports errors
  then, stop and do not start atlas until they are understood.
