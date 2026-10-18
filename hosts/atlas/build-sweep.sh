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
rc=0

RUST=(-name target -o -name '*-target')
WEB=("${RUST[@]}" -o -name node_modules -o -name .next -o -name dist -o -name build
  -o -name .turbo -o -name .cache -o -name coverage -o -name out -o -name .vite)

avail() { df -h --output=avail "$S" | tail -1 | tr -d ' '; }

# Paths in use, one per line: every process cwd and every CARGO_TARGET_DIR.
inuse=$'\n'$({
  find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%l\n' 2>/dev/null || true
  grep -ahz '^CARGO_TARGET_DIR=' /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' | cut -d= -f2- || true
} | sort -u)$'\n'

# A process works in $1 or below it, or has its CARGO_TARGET_DIR there.
in_use() { case $inuse in *$'\n'"$1"$'\n'* | *$'\n'"$1"/*) return 0 ;; esac; return 1; }

# Something below $1 was written in the last 120 minutes. .git and
# node_modules count by their own mtime but are not descended into.
recent() {
  [ -n "$(find "$1" -maxdepth 3 \( -mmin -120 -print -quit \) -o \
    \( -name .git -o -name node_modules \) -prune 2>/dev/null)" ]
}

# Git tracks something in $1. Root reads the agents' repos, hence safe.directory.
tracked() {
  [ -n "$(git -c safe.directory='*' -C "${1%/*}" ls-files -- "${1##*/}" 2>/dev/null | head -1)" ]
}

# Remove matching build directories below $1 that git does not track; the
# remaining arguments are a find name expression. .git is never entered.
prune_builds() {
  local d=$1 b
  shift
  find "$d" -xdev \( -name .git -prune \) -o -type d \( "$@" \) -prune -print0 2>/dev/null |
    while IFS= read -r -d '' b; do
      tracked "$b" || rm -rf "$b"
    done || true
}

echo "sweep start, $(avail) free on $S"

# 1) Worktrees whose threads are all settled, archived or deleted, and quiet
#    for two hours: all build and install output. A worktree can be shared by
#    several threads, so one active thread keeps it. Worktrees swept before
#    and untouched since are skipped; the list is rebuilt every run, so
#    removed worktrees drop out of it.
if ! worktrees=$(sqlite3 -readonly "$DB" "select worktree_path from projection_threads
  where worktree_path is not null group by worktree_path
  having min(deleted_at is not null or archived_at is not null
    or (settled_at is not null and (unsettled_at is null or unsettled_at < settled_at))) = 1
  and max(updated_at) < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-2 hours')"); then
  echo "reading threads from $DB failed, skipping worktrees" >&2
  rc=1
fi
touch "$SWEPT"
declare -A swept=()
while read -r wt; do if [ -n "$wt" ]; then swept[$wt]=1; fi; done <"$SWEPT"
while read -r wt; do
  [ -d "$wt" ] || continue
  if [ -n "${swept[$wt]:-}" ] && [ -z "$(find "$wt" -maxdepth 2 -newer "$SWEPT" -print -quit 2>/dev/null)" ]; then
    echo "$wt"
    continue
  fi
  if in_use "$wt" || recent "$wt"; then continue; fi
  prune_builds "$wt" "${WEB[@]}"
  echo "$wt"
done <<<"$worktrees" | sort -u >"$SWEPT.tmp"
mv "$SWEPT.tmp" "$SWEPT"
echo "worktrees done, $(avail) free"

# 2) Cargo output in the agents' scratch area, workspace checkouts and temp.
#    The tmpfiles age rules for these (configuration.nix) take days; cargo
#    fills the disk in hours.
find "$W" "$S/tmp" /tmp -xdev \( -name .git -o -name node_modules -o -name .next -o -name .cache \) -prune \
  -o -type d \( "${RUST[@]}" \) -prune -print0 2>/dev/null |
  while IFS= read -r -d '' d; do
    in_use "${d%/*}" || in_use "$d" || recent "$d" || tracked "$d" || rm -rf "$d"
  done || true

echo "sweep end, $(avail) free on $S"
exit $rc
