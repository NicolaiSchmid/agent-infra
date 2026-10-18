# Hourly sweep of build output on atlas.
#
# Agents leave cargo target directories and node build output behind in every
# worktree and scratch checkout; on 2026-10-04 they grew the state disk by
# ~30 GB/h and filled black underneath the VM. This removes only directories
# with build-output names that git ignores and tracks nothing in (or, outside
# git, cargo output marked by CACHEDIR.TAG). Never .git, never sources. It
# skips anything in use: a process has its cwd or CARGO_TARGET_DIR there, or
# something within three levels was written in the last $QUIET_MIN minutes.
#
# DRY_RUN=1 atlas-build-sweep logs what it would remove and changes nothing.
# Operations and rollback: runbooks/atlas-build-sweep.md.
shopt -s nullglob

AGENTS=/srv/agents-state
WORKSPACE=$AGENTS/workspace
THREADS_DB=$AGENTS/t3code/userdata/statev2.sqlite
STATE=${STATE_DIRECTORY:-/var/lib/atlas-build-sweep}
SWEPT=$STATE/swept-worktrees.txt
QUIET_MIN=120
DRY_RUN=${DRY_RUN:-}
rc=0

RUST=(-name target -o -name '*-target')
WEB=("${RUST[@]}" -o -name node_modules -o -name .next -o -name dist -o -name build
  -o -name .turbo -o -name .cache -o -name coverage -o -name out -o -name .vite)

avail() { df -h --output=avail "$AGENTS" | tail -1 | tr -d ' '; }
git_() { git -c safe.directory='*' "$@"; }
threads() { sqlite3 -readonly "$THREADS_DB" "$1"; }

# Paths in use, one per line: every process cwd and every CARGO_TARGET_DIR
# (normalised; relative ones resolved against that process's cwd). Re-read
# before each worktree is pruned, because removing node_modules can take
# minutes.
busy_paths=
scan_busy() {
  local f pid dir
  busy_paths=$'\n'$({
    find /proc -mindepth 2 -maxdepth 2 -name cwd -printf '%l\n' 2>/dev/null || true
    for f in $(grep -lz '^CARGO_TARGET_DIR=' /proc/[0-9]*/environ 2>/dev/null || true); do
      pid=${f#/proc/}
      pid=${pid%/environ}
      dir=$(tr '\0' '\n' <"$f" 2>/dev/null | sed -n 's/^CARGO_TARGET_DIR=//p' | head -1) || continue
      case $dir in
      /*) realpath -m -- "$dir" ;;
      ?*) realpath -m -- "$(readlink "/proc/$pid/cwd" 2>/dev/null)/$dir" ;;
      esac
    done
  } | sort -u)$'\n'
}

# A process works in $1 or below it, or has its CARGO_TARGET_DIR there.
in_use() { case $busy_paths in *$'\n'"$1"$'\n'* | *$'\n'"$1"/*) return 0 ;; esac; return 1; }

# Something within three levels below $1 matches the find test in the
# remaining arguments. .git and node_modules count by their own mtime but are
# not descended into.
written() {
  local d=$1
  shift
  [ -n "$(find "$d" -maxdepth 3 \( "$@" -print -quit \) -o \
    \( -name .git -o -name node_modules \) -prune 2>/dev/null)" ]
}
recent() { written "$1" -mmin "-$QUIET_MIN"; }

# $1 is build output: inside a git work tree, git tracks nothing in it and
# ignores it (or cargo marked it); outside git, only cargo output counts.
# A worktree whose gitdir is gone counts as outside git. *-target only means
# a cargo target dir when cargo marked it (deepsec keeps scan data under such
# names).
deletable() {
  local parent=${1%/*} name=${1##*/}
  case $name in *-target) [ -e "$1/CACHEDIR.TAG" ] || return 1 ;; esac
  if git_ -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [ -z "$(git_ -C "$parent" ls-files -- "$name" 2>/dev/null | head -1)" ] || return 1
    [ -e "$1/CACHEDIR.TAG" ] || git_ -C "$parent" check-ignore -q -- "$name"
  else
    [ -e "$1/CACHEDIR.TAG" ]
  fi
}

remove() {
  echo "remove $1"
  [ -n "$DRY_RUN" ] || rm -rf --one-file-system -- "$1"
}

# Remove build directories below $1; the remaining arguments are a find name
# expression. .git is never entered.
prune_builds() {
  local d=$1 b
  shift
  find "$d" -xdev -name .git -prune -o -type d \( "$@" \) -prune -print0 2>/dev/null |
    while IFS= read -r -d '' b; do
      if deletable "$b"; then remove "$b"; fi
    done || true
}

echo "sweep start, $(avail) free on $AGENTS${DRY_RUN:+ (dry run)}"

# 1) Worktrees (and t3code scratch dirs) whose threads are all settled,
#    archived or deleted, have no live run, and were not updated for
#    $QUIET_MIN minutes: all build and install output. Several threads can
#    share a worktree, so one active thread keeps it. Worktrees swept before
#    and unchanged since the last run started are skipped; the list is
#    rebuilt every run, so removed worktrees drop out of it.
#    A projection that stopped updating for a day (t3code moved its state, as
#    0.1.0 did from state.sqlite) fails the unit instead of sweeping on stale
#    data.
fresh=$(threads "select max(updated_at) > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-1 day')
  from orchestration_v2_projection_threads") || fresh=
if [ "$fresh" = 1 ] && worktrees=$(threads "
  with t as (select thread_id, updated_at, json_extract(payload_json, '$.worktreePath') as wt,
      (archived_at is not null or deleted_at is not null
       or json_extract(payload_json, '$.settledAt') is not null) as idle
    from orchestration_v2_projection_threads),
  live as (select thread_id from orchestration_v2_projection_runs
    where status in ('queued', 'preparing', 'starting', 'running', 'waiting'))
  select wt from t where wt is not null group by wt
  having min(idle and thread_id not in live) = 1
    and max(updated_at) < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$QUIET_MIN minutes')"); then
  stamp=$STATE/run-started
  [ -n "$DRY_RUN" ] || touch "$stamp"
  declare -A swept=()
  if [ -e "$SWEPT" ]; then
    while IFS= read -r wt; do if [ -n "$wt" ]; then swept[$wt]=1; fi; done <"$SWEPT"
  fi
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    if [ -n "${swept[$wt]:-}" ] && ! written "$wt" -newer "$SWEPT"; then
      echo "$wt"
      continue
    fi
    scan_busy
    if in_use "$wt" || recent "$wt"; then continue; fi
    prune_builds "$wt" "${WEB[@]}" >&2
    echo "$wt"
  done <<<"$worktrees" | sort -u >"$STATE/swept.tmp"
  # The list's mtime is when this run started, for the -newer test above.
  if [ -n "$DRY_RUN" ]; then
    rm -f "$STATE/swept.tmp"
  else
    mv "$STATE/swept.tmp" "$SWEPT"
    touch -r "$stamp" "$SWEPT"
  fi
else
  echo "thread projection in $THREADS_DB unreadable or stale, skipping worktrees" >&2
  rc=1
fi
echo "worktrees done, $(avail) free"

# 2) Cargo output in the agents' scratch area, workspace checkouts and temp.
#    The tmpfiles age rules for these (configuration.nix) take days; cargo
#    fills the disk in hours. A target dir is also kept while a process works
#    anywhere in the crate around it. Other services' private /tmp and nix
#    build dirs are left alone.
scan_busy
find "$WORKSPACE" "$AGENTS/tmp" /tmp -xdev \( -name .git -o -name node_modules -o -name .next -o -name .cache \
  -o -path '/tmp/systemd-private-*' -o -path '/tmp/nix-build-*' \) -prune \
  -o -type d \( "${RUST[@]}" \) -prune -print0 2>/dev/null |
  while IFS= read -r -d '' d; do
    in_use "${d%/*}" || in_use "$d" || recent "$d" || ! deletable "$d" || remove "$d"
  done || true

echo "sweep end, $(avail) free on $AGENTS"
# rm errors are not counted: the next run retries those paths.
exit $rc
