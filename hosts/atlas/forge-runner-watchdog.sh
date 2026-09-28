# Keep the LINUX_RUNS_ON / MACOS_RUNS_ON repository variables pointed at the
# best available self-hosted runners (Linux: atlas, then Forge; macOS: Forge)
# and at GitHub-hosted runners otherwise. Workflows consume them with
#   runs-on: ${{ fromJSON(vars.LINUX_RUNS_ON || '"ubuntu-latest"') }}
# Runs from a systemd timer on atlas as nicolai (gh auth in $HOME).

repos=(
  NicolaiSchmid/june
  NicolaiSchmid/fifthset
  NicolaiSchmid/mietprofi
  NicolaiSchmid/mosaic
  NicolaiSchmid/nicolaischmid.de
  NicolaiSchmid/steno
)

# Repositories whose Linux jobs run the same on x86_64 and arm64: when both
# atlas and the Forge VM are online they get the arch-neutral label set, so
# GitHub hands each job to whichever runner is idle and the Forge VM absorbs
# overflow instead of sitting idle. june and fifthset stay x86_64-only: their
# expo exports run hermesc, which is x86_64-only and emulated on arm64.
arch_neutral=(
  NicolaiSchmid/mietprofi
  NicolaiSchmid/mosaic
  NicolaiSchmid/nicolaischmid.de
)

linux_forge='["self-hosted","Linux","ARM64"]'
linux_hosted='"ubuntu-latest"'
macos_forge='["self-hosted","macOS","ARM64"]'
macos_hosted='"macos-15"'

linux_atlas='["self-hosted","Linux","X64"]'
linux_any='["self-hosted","Linux"]'

# online_count REPO HOST_LABEL OS_LABEL -> number of online runners carrying both labels
online_count() {
  gh api "repos/$1/actions/runners?per_page=100" |
    jq --arg host "$2" --arg os "$3" '[.runners[]
      | select(.status == "online")
      | select((.labels | map(.name)) | index($host))
      | select((.labels | map(.name)) | index($os))] | length'
}

# set_var REPO NAME VALUE -> write the variable only when it changes
set_var() {
  local current
  current=$(gh variable get "$2" -R "$1" 2>/dev/null || true)
  if [ "$current" != "$3" ]; then
    gh variable set "$2" -R "$1" --body "$3"
    echo "$1: $2 -> $3"
  fi
}

# is_arch_neutral REPO
is_arch_neutral() {
  local r
  for r in "${arch_neutral[@]}"; do [ "$r" = "$1" ] && return 0; done
  return 1
}

for repo in "${repos[@]}"; do
  atlas_online=$(online_count "$repo" atlas Linux)
  forge_online=$(online_count "$repo" forge Linux)
  # Linux: atlas (always-on x86_64 VM) first, then the Forge arm64 VM, then
  # hosted. Arch-neutral repositories use both tiers at once when both are up.
  if [ "$atlas_online" -gt 0 ] && [ "$forge_online" -gt 0 ] && is_arch_neutral "$repo"; then
    set_var "$repo" LINUX_RUNS_ON "$linux_any"
  elif [ "$atlas_online" -gt 0 ]; then
    set_var "$repo" LINUX_RUNS_ON "$linux_atlas"
  elif [ "$forge_online" -gt 0 ]; then
    set_var "$repo" LINUX_RUNS_ON "$linux_forge"
  else
    set_var "$repo" LINUX_RUNS_ON "$linux_hosted"
  fi
  if [ "$(online_count "$repo" forge macOS)" -gt 0 ]; then
    set_var "$repo" MACOS_RUNS_ON "$macos_forge"
  else
    set_var "$repo" MACOS_RUNS_ON "$macos_hosted"
  fi
done
