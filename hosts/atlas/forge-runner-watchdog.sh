# Keep the MACOS_RUNS_ON repository variable pointed at the Forge macOS runners
# while they are online and at a GitHub-hosted macOS image otherwise.
# Workflows consume it with
#   runs-on: ${{ fromJSON(vars.MACOS_RUNS_ON || '"macos-15"') }}
# Linux jobs run on Ubicloud (`runs-on: ubicloud-standard-N` in each workflow)
# and are not managed here.
# Runs from a systemd timer on atlas as nicolai (gh auth in $HOME).

# Repositories whose workflows read MACOS_RUNS_ON, with the hosted fallback
# their workflows use as the default (`vars.MACOS_RUNS_ON || '"<image>"'`).
declare -A repos=(
  [NicolaiSchmid/june]=macos-15
  [NicolaiSchmid/fifthset]=macos-15
  [NicolaiSchmid/mietprofi]=macos-15
  [NicolaiSchmid/ilovegrain]=macos-26
)

macos_forge='["self-hosted","macOS","ARM64"]'

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

for repo in "${!repos[@]}"; do
  if [ "$(online_count "$repo" forge macOS)" -gt 0 ]; then
    set_var "$repo" MACOS_RUNS_ON "$macos_forge"
  else
    set_var "$repo" MACOS_RUNS_ON "\"${repos[$repo]}\""
  fi
done
