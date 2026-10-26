# Type checks, tests and dev servers that agents start (tsc, vitest, eslint,
# next, playwright, ...) run inside t3code.service next to the server. On
# 2026-10-20 ~25 parallel lanes of them pushed atlas into swap until sshd and
# Tailscale stopped answering. They cannot be started in their own unit, so a
# small loop moves them into agent-checks.slice, which caps them together.
{pkgs, ...}: let
  holder = "agent-checks-holder.service";
  mover = pkgs.writeShellApplication {
    name = "atlas-agent-checks-mover";
    runtimeInputs = with pkgs; [procps gnugrep coreutils];
    text = ''
      procs=/sys/fs/cgroup/agent.slice/agent-checks.slice/${holder}/cgroup.procs
      while true; do
        for p in $(pgrep -u nicolai -f 'tsc|vitest|eslint|next-server|next dev|playwright|esbuild|biome' || true); do
          # CI jobs run as ghr-* users, but be explicit about runner paths.
          grep -q github-runners "/proc/$p/cmdline" 2>/dev/null && continue
          echo "$p" >"$procs" 2>/dev/null || true
        done
        sleep 3
      done
    '';
  };
  # The slice caps memory and CPU, but with ~15 parallel lanes it still held
  # 280 processes (load 140) that all swapped against the cap. Agents also
  # start checks as `systemd-run --user` units in the user manager's app.slice,
  # where they escaped the cap (25G with swap on 2026-10-26). The gate counts
  # both as runs: a process tree in agent-checks.slice, or a unit in app.slice.
  # At most `maxRuns` run at a time, oldest first; the rest are paused
  # (SIGSTOP, or cgroup.freeze for units). Dev servers are never paused, so
  # long-lived ones cannot hold the slots forever.
  maxRuns = 5;
  appSlice = "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice";
  gate = pkgs.writeShellApplication {
    name = "atlas-agent-checks-gate";
    runtimeInputs = with pkgs; [coreutils gawk gnugrep];
    text = ''
      procs=/sys/fs/cgroup/agent.slice/agent-checks.slice/${holder}/cgroup.procs
      app=${appSlice}
      server='next dev|next-server|next start|vite( |$)|convex dev|webpack serve|storybook'
      started() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
      is_server() { tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null | grep -Eq "$server"; }
      while true; do
        declare -A member=() runs=()
        while read -r p; do member[$p]=1; done <"$procs"
        for p in "''${!member[@]}"; do
          r=$p
          while pp=$(awk '{print $4}' "/proc/$r/stat" 2>/dev/null) && [ -n "''${member[$pp]:-}" ]; do
            r=$pp
          done
          runs[$r]+="$p "
        done
        list=$(
          for r in "''${!runs[@]}"; do
            # shellcheck disable=SC2086
            if is_server "$r"; then kill -CONT ''${runs[$r]} 2>/dev/null || true; continue; fi
            echo "$(started "$r") p:$r"
          done
          for d in "$app"/*; do
            [ -e "$d/cgroup.freeze" ] || continue
            first=
            while read -r p; do
              t=$(started "$p") || continue
              if is_server "$p"; then first=server; break; fi
              if [ -z "$first" ] || [ "$t" -lt "$first" ]; then first=$t; fi
            done < <(cat "$d"/cgroup.procs "$d"/*/cgroup.procs 2>/dev/null)
            case $first in
            "") ;;
            server) echo 0 >"$d/cgroup.freeze" 2>/dev/null || true ;;
            *) echo "$first u:$d" ;;
            esac
          done
        )
        i=0
        while read -r _ run; do
          [ -n "$run" ] || continue
          if [ "$i" -lt ${toString maxRuns} ]; then go=1; else go=0; fi
          # shellcheck disable=SC2086
          case $run in
          p:*) if [ $go = 1 ]; then kill -CONT ''${runs[''${run#p:}]} 2>/dev/null || true; else kill -STOP ''${runs[''${run#p:}]} 2>/dev/null || true; fi ;;
          u:*) echo $((1 - go)) >"''${run#u:}/cgroup.freeze" 2>/dev/null || true ;;
          esac
          i=$((i + 1))
        done < <(sort -n <<<"$list")
        unset member runs
        sleep 5
      done
    '';
  };
in {
  systemd.services.agent-checks-gate = {
    description = "Run at most ${toString maxRuns} agent check runs at a time";
    wantedBy = ["multi-user.target"];
    after = [holder];
    requires = [holder];
    # On stop, let every paused check and frozen unit continue.
    postStop = ''
      for f in ${appSlice}/*/cgroup.freeze ${appSlice}/cgroup.freeze; do
        echo 0 >"$f" 2>/dev/null || true
      done
      for p in $(cat /sys/fs/cgroup/agent.slice/agent-checks.slice/${holder}/cgroup.procs 2>/dev/null); do
        kill -CONT "$p" 2>/dev/null || true
      done
    '';
    serviceConfig = {
      ExecStart = "${gate}/bin/atlas-agent-checks-gate";
      Restart = "always";
    };
  };

  # The user manager's app.slice, where `systemd-run --user` units land.
  systemd.user.slices.app.sliceConfig = {
    CPUWeight = 20;
    IOWeight = 10;
    MemoryHigh = "10G";
    MemoryMax = "12G";
    MemorySwapMax = "3G";
  };

  systemd.slices.agent-checks = {
    description = "Checks and dev servers started by agents (capped)";
    sliceConfig = {
      CPUWeight = 20;
      IOWeight = 10;
      CPUQuota = "400%";
      MemoryHigh = "10G";
      MemoryMax = "12G";
      MemorySwapMax = "2G";
    };
  };

  # Keeps the slice's cgroup alive so the mover has a target. OOMPolicy=continue:
  # an OOM kill inside the slice must not stop the holder (it did on 2026-10-20,
  # which lifted the cap for 14 hours).
  systemd.services.agent-checks-holder = {
    description = "Cgroup anchor for agent-checks.slice";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Slice = "agent-checks.slice";
      ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
      OOMPolicy = "continue";
      Restart = "always";
    };
  };

  systemd.services.agent-checks-mover = {
    description = "Move agent checks into agent-checks.slice";
    wantedBy = ["multi-user.target"];
    after = [holder];
    requires = [holder];
    serviceConfig = {
      ExecStart = "${mover}/bin/atlas-agent-checks-mover";
      Restart = "always";
      Nice = 5;
    };
  };
}
