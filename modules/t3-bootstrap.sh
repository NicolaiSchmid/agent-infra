#!/usr/bin/env bash
set -euo pipefail
state_dir=$1
bootstrap_runtime=$2
bootstrap_version=$3
runtime_dir="$state_dir/runtime"
state_file="$runtime_dir/service-state.json"
mkdir -p "$runtime_dir/versions" "$state_dir/userdata"
staging_dir=$(mktemp -d "$runtime_dir/.bootstrap.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

# First adoption is not an upstream update trial. Save the stopped server's
# SQLite files and settings before the new runtime can migrate them.
# The databases can be tens of GiB (Atlas), so copy them exactly once, refuse
# to start rather than fill the disk, and keep a completed backup from an
# earlier failed attempt instead of adding another. An interrupted copy only
# leaves the fixed partial directory, which the next attempt replaces.
if [ ! -e "$state_file" ] && ! compgen -G "$runtime_dir/pre-launcher-backup.*" >/dev/null; then
  partial="$runtime_dir/.pre-launcher-backup.partial"
  rm -rf "$partial"
  files=()
  for file in "$state_dir"/userdata/*.sqlite "$state_dir"/userdata/*.sqlite-wal "$state_dir"/userdata/*.sqlite-shm "$state_dir"/userdata/settings.json; do
    if [ -f "$file" ]; then files+=("$file"); fi
  done
  if [ "${#files[@]}" -gt 0 ]; then
    need=$(du -cb -- "${files[@]}" | tail -n 1 | cut -f 1)
    avail=$(df --output=avail -B1 "$runtime_dir" | tail -n 1 | tr -d ' ')
    reserve=$((2 * 1024 * 1024 * 1024))
    if [ $((need + reserve)) -gt "$avail" ]; then
      echo "t3code-bootstrap: adoption backup needs $need bytes plus $reserve reserve, only $avail free in $runtime_dir" >&2
      exit 1
    fi
  fi
  mkdir -m 700 "$partial"
  for file in "${files[@]}"; do cp -p "$file" "$partial/"; done
  saved_backup=$(mktemp -d "$runtime_dir/pre-launcher-backup.XXXXXX")
  rmdir "$saved_backup"
  mv "$partial" "$saved_backup"
fi

# The requested fleet policy: eligible interrupted turns resume after restart.
# Preserve the rest of the settings, including credentials and project choices.
settings="$state_dir/userdata/settings.json"
if [ -f "$settings" ]; then
  jq '.continueThreadsAfterServerUpdate = true' "$settings" > "$staging_dir/settings"
else
  printf '{"continueThreadsAfterServerUpdate":true}\n' > "$staging_dir/settings"
fi
chmod 600 "$staging_dir/settings"
mv "$staging_dir/settings" "$settings"

# Never replace pending update/rollback state or downgrade an updated runtime.
if [ -e "$state_file" ]; then
  exit 0
fi
version_dir="$runtime_dir/versions/$bootstrap_version"
if [ ! -e "$version_dir" ]; then
  mkdir "$staging_dir/version"
  cp -R "$bootstrap_runtime/." "$staging_dir/version/"
  chmod -R u+w "$staging_dir/version"
  mv "$staging_dir/version" "$version_dir"
fi
test -x "$version_dir/t3"
test "$(cat "$version_dir/.install-complete")" = "$bootstrap_version"
printf '{"protocol":3,"activeVersion":"%s"}\n' "$bootstrap_version" > "$staging_dir/state"
chmod 600 "$staging_dir/state"
mv "$staging_dir/state" "$state_file"
