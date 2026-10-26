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
  # 280 processes (load 140) that all swapped against the cap. The gate runs
  # at most `maxRuns` check runs (a process tree in the slice) at a time and
  # pauses the others with SIGSTOP, resuming them oldest first.
  maxRuns = 4;
  gate = pkgs.writeShellApplication {
    name = "atlas-agent-checks-gate";
    runtimeInputs = with pkgs; [coreutils gawk];
    text = ''
      procs=/sys/fs/cgroup/agent.slice/agent-checks.slice/${holder}/cgroup.procs
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
        i=0
        # Oldest run first (start time is field 22 of /proc/<pid>/stat).
        for r in $(for q in "''${!runs[@]}"; do
          echo "$(awk '{print $22}' "/proc/$q/stat" 2>/dev/null) $q"
        done | sort -n | awk '{print $2}'); do
          if [ "$i" -lt ${toString maxRuns} ]; then sig=CONT; else sig=STOP; fi
          # shellcheck disable=SC2086
          kill -"$sig" ''${runs[$r]} 2>/dev/null || true
          i=$((i + 1))
        done
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
    # On stop, let every paused check continue.
    postStop = ''
      for p in $(cat /sys/fs/cgroup/agent.slice/agent-checks.slice/${holder}/cgroup.procs 2>/dev/null); do
        kill -CONT "$p" 2>/dev/null || true
      done
    '';
    serviceConfig = {
      ExecStart = "${gate}/bin/atlas-agent-checks-gate";
      Restart = "always";
    };
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
