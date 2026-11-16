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
if [ ! -e "$state_file" ]; then
  backup="$staging_dir/backup"
  mkdir -m 700 "$backup"
  for file in "$state_dir"/userdata/*.sqlite "$state_dir"/userdata/*.sqlite-wal "$state_dir"/userdata/*.sqlite-shm "$state_dir"/userdata/settings.json; do
    if [ -f "$file" ]; then cp -p "$file" "$backup/"; fi
  done
  # A unique retained directory also makes retrying a failed adoption safe.
  saved_backup=$(mktemp -d "$runtime_dir/pre-launcher-backup.XXXXXX")
  chmod 700 "$saved_backup"
  cp -R "$backup/." "$saved_backup/"
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
