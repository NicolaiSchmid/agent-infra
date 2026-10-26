# Move agent checks (tsc, eslint, vitest, next) out of t3code.service into
# agentchecks.slice, one transient scope per check.
#
# Every agent session runs inside t3code.service, so its checks would compete
# with the server and the sessions themselves. Each matching process found
# there, with every descendant it already has, goes into its own
# agentcheck-<pid>.scope; processes it forks later are born in that scope.
# A scope carries its own memory cap, so one runaway vitest is OOM-killed on
# its own instead of filling the slice, and it disappears with its process:
# there is no shared holder unit whose failure could stop later moves.
#
# The mover only moves processes and raises their oom_score_adj (so a global
# OOM kills a check before an agent session); it never signals anything.
# Operations and rollback: runbooks/atlas-agentchecks.md.
SRC=/sys/fs/cgroup/system.slice/t3code.service/cgroup.procs
SLICE=agentchecks.slice
# Matched against the first two words of the command line, so `rg vitest` or
# `cat node_modules/vitest/package.json` stay where they are.
PATTERN='(^|/)(tsc|eslint|vitest|next)( |$)|/typescript/bin/tsc( |$)|/eslint/bin/eslint\.js|/vitest/vitest\.mjs|/next/dist/bin/next|^next-server'
: "${SCOPE_MEMORY_MAX:?}" "${SCOPE_SWAP_MAX:?}"
OOM_SCORE_ADJ=500
INTERVAL=2

move() { # root pid, description, pids...
  local root=$1 desc=$2
  shift 2
  local p adj
  for p in "$@"; do
    read -r adj 2>/dev/null <"/proc/$p/oom_score_adj" || continue
    ((adj >= OOM_SCORE_ADJ)) || echo "$OOM_SCORE_ADJ" 2>/dev/null >"/proc/$p/oom_score_adj" || true
  done
  if busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
    "agentcheck-$root.scope" fail 7 \
    PIDs au "$#" "$@" \
    Slice s "$SLICE" \
    Description s "agent check: $desc" \
    MemoryMax t "$SCOPE_MEMORY_MAX" \
    MemorySwapMax t "$SCOPE_SWAP_MAX" \
    OOMPolicy s stop \
    CollectMode s inactive-or-failed \
    0 >/dev/null; then
    echo "moved $root ($# processes): $desc"
  fi
}

while sleep "$INTERVAL"; do
  declare -A parent=() children=() hit=()
  mapfile -t pids <"$SRC" || continue
  for pid in "${pids[@]}"; do
    read -r stat 2>/dev/null <"/proc/$pid/stat" || continue
    # comm (field 2) may contain spaces and parentheses; ppid follows state.
    read -r _ ppid _ <<<"${stat##*) }"
    parent[$pid]=$ppid
    children[$ppid]+=" $pid"
    { mapfile -d '' -t argv <"/proc/$pid/cmdline"; } 2>/dev/null || continue
    ((${#argv[@]})) || continue
    head="${argv[0]} ${argv[1]:-}"
    [[ $head =~ $PATTERN ]] && hit[$pid]="${argv[*]:0:4}"
  done
  for pid in "${!hit[@]}"; do
    # A matching child of a matching process moves with its parent.
    [[ -n ${hit[${parent[$pid]}]+x} ]] && continue
    tree=() queue=("$pid")
    while ((${#queue[@]})); do
      p=${queue[0]}
      queue=("${queue[@]:1}")
      tree+=("$p")
      # shellcheck disable=SC2206 # word-splitting the child list is intended
      queue+=(${children[$p]:-})
    done
    move "$pid" "${hit[$pid]:0:120}" "${tree[@]}"
  done
done
