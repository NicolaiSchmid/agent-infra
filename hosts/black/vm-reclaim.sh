# Repack partially referenced Btrfs extents without changing VM disk contents.
# Guest FITRIM can leave unused pieces pinned inside large host extents.
set -euo pipefail
state=${STATE_DIRECTORY:-/var/lib/atlas-vm-reclaim}
mkdir -p "$state"
exec 9>"$state/lock"
flock -n 9 || exit 0
images=(/var/lib/libvirt/images/atlas-state.raw /var/lib/libvirt/images/atlas-root.raw)
index=0
offset=0
if [ -f "$state/cursor" ]; then read -r index offset < "$state/cursor"; fi
[[ $index =~ ^[01]$ && $offset =~ ^[0-9]+$ ]] || { echo 'Invalid reclaim cursor' >&2; exit 1; }
# Eight 1-GiB windows per run. Flush every 16 MiB to bound dirty data.
for ((window=0; window<8; window++)); do
  available=$(df -B1 --output=avail / | tail -1 | tr -d ' ')
  [ "$available" -lt 107374182400 ] || exit 0
  [ "$available" -ge 8589934592 ] || { echo 'Less than 8 GiB headroom; refusing relocation' >&2; exit 1; }
  image=${images[$index]}
  [ -f "$image" ] && [ ! -L "$image" ] || exit 1
  # Never break reflinks/snapshots. The VM images must remain exclusive NOCOW.
  attributes=$(lsattr -d "$image" | awk '{print $1}')
  [[ $attributes == *C* ]] || { echo "Not NOCOW: $image" >&2; exit 1; }
  btrfs filesystem du --raw -s "$image" |
    awk 'NR==2 {found=1; if ($1 != $2 || $3 != 0) exit 1} END {if (!found) exit 1}' || {
      echo "Shared extents or unreadable extent information: $image" >&2; exit 1;
    }
  size=$(stat -c %s "$image")
  if [ "$offset" -ge "$size" ]; then index=$((1-index)); offset=0; image=${images[$index]}; continue; fi
  btrfs filesystem defragment --nocomp -f -s "$offset" -l 1G -t 128M --step 16M "$image"
  btrfs filesystem sync /
  offset=$((offset+1073741824))
  printf '%s %s\n' "$index" "$offset" > "$state/cursor.new"
  mv "$state/cursor.new" "$state/cursor"
  echo "Repacked $image through $offset bytes; $(df -h --output=avail / | tail -1) free"
done
