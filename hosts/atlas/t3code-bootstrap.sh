#!/usr/bin/env bash
# Seed a new T3 home once. Never reset an updater-selected version or pending
# update/rollback, even when Nix's bootstrap pin changes.
set -euo pipefail
state_dir=$1
bootstrap_runtime=$2
bootstrap_version=$3
runtime_dir="$state_dir/runtime"
state_file="$runtime_dir/service-state.json"

if [ -e "$state_file" ]; then
  exit 0
fi

mkdir -p "$runtime_dir/versions"
version_dir="$runtime_dir/versions/$bootstrap_version"
staging_dir=$(mktemp -d "$runtime_dir/.bootstrap.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

if [ ! -e "$version_dir" ]; then
  mkdir "$staging_dir/version"
  cp -R "$bootstrap_runtime/." "$staging_dir/version/"
  chmod -R u+w "$staging_dir/version"
  mv "$staging_dir/version" "$version_dir"
fi
test -x "$version_dir/t3"
test "$(cat "$version_dir/.install-complete")" = "$bootstrap_version"

# Protocol 3 is the standalone-runtime layout used by the pinned launcher.
printf '{"protocol":3,"activeVersion":"%s"}\n' "$bootstrap_version" > "$staging_dir/state"
chmod 600 "$staging_dir/state"
mv "$staging_dir/state" "$state_file"
