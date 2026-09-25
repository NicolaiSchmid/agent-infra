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

linux_forge='["self-hosted","Linux","ARM64"]'
linux_hosted='"ubuntu-latest"'
macos_forge='["self-hosted","macOS","ARM64"]'
macos_hosted='"macos-15"'

linux_atlas='["self-hosted","Linux","X64"]'

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

for repo in "${repos[@]}"; do
  # Linux: atlas (always-on x86_64 VM) first, then the Forge arm64 VM, then hosted.
  if [ "$(online_count "$repo" atlas Linux)" -gt 0 ]; then
    set_var "$repo" LINUX_RUNS_ON "$linux_atlas"
  elif [ "$(online_count "$repo" forge Linux)" -gt 0 ]; then
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
