# Hourly sweep of build output on atlas.
#
# Agents leave cargo target directories and node build output behind in every
# worktree and scratch checkout; on 2026-10-04 they grew the state disk by
# ~30 GB/h and filled black underneath the VM. This removes only build
# artefacts, never sources or .git, and skips anything in use: a process has
# its cwd or CARGO_TARGET_DIR there, or something was written in the last
# 120 minutes.
shopt -s nullglob

S=/srv/agents-state
W=$S/workspace
STATE=${STATE_DIRECTORY:-/var/lib/atlas-build-sweep}
DB=$S/t3code/userdata/state.sqlite
SWEPT=$STATE/swept-worktrees.txt
INUSE=$STATE/in-use.txt

RUST=(-name target -o -name '*-target')
WEB=(-name node_modules -o -name .next -o -name dist -o -name build -o -name target
  -o -name .turbo -o -name .cache -o -name coverage -o -name out -o -name .vite)

avail() { df -h --output=avail "$S" | tail -1 | tr -d ' '; }

# Paths in use: every process cwd and every CARGO_TARGET_DIR.
: >"$INUSE"
for p in /proc/[0-9]*; do
  readlink "$p/cwd" 2>/dev/null >>"$INUSE" || true
  tr '\0' '\n' <"$p/environ" 2>/dev/null | sed -n 's/^CARGO_TARGET_DIR=//p' >>"$INUSE" || true
done
sort -u -o "$INUSE" "$INUSE"

busy() {
  local d=$1
  grep -q -e "^$d\$" -e "^$d/" "$INUSE" && return 0
  [ -n "$(find "$d" -maxdepth 3 -mmin -120 -print -quit 2>/dev/null)" ]
}

# Remove matching build directories below $1; the remaining arguments are a
# find name expression. .git is never entered.
prune_builds() {
  local d=$1
  shift
  find "$d" -xdev \( -name .git -prune \) -o -type d \( "$@" \) -prune -exec rm -rf {} + 2>/dev/null || true
}

echo "sweep start, $(avail) free on $S"

# 1) Worktrees of settled, archived or deleted threads: all build and install
#    output. Worktrees swept before and untouched since are skipped.
touch "$SWEPT"
: >"$STATE/swept.new"
sqlite3 -readonly "$DB" "select worktree_path from projection_threads
  where worktree_path is not null and (deleted_at is not null or archived_at is not null
  or (settled_at is not null and (unsettled_at is null or unsettled_at < settled_at)))" 2>/dev/null |
  while read -r wt; do
    [ -d "$wt" ] || continue
    if grep -qxF "$wt" "$SWEPT" && [ -z "$(find "$wt" -maxdepth 2 -newer "$SWEPT" -print -quit 2>/dev/null)" ]; then
      continue
    fi
    busy "$wt" && continue
    prune_builds "$wt" "${WEB[@]}"
    echo "$wt" >>"$STATE/swept.new"
  done
sort -u "$SWEPT" "$STATE/swept.new" >"$STATE/swept.tmp" && mv "$STATE/swept.tmp" "$SWEPT"
rm -f "$STATE/swept.new"
echo "worktrees done, $(avail) free"

# 2) Cargo output in the agents' scratch area, workspace checkouts and temp.
for d in "$W"/.tools/*/ "$W"/*/ "$W"/*/*/ "$S"/tmp/*/ /tmp/*/; do
  d=${d%/}
  case "$d" in "$W/.tools") continue ;; esac
  busy "$d" && continue
  case "$d" in
  *-target) rm -rf "$d" ;;
  *) prune_builds "$d" "${RUST[@]}" ;;
  esac
done

echo "sweep end, $(avail) free on $S"
