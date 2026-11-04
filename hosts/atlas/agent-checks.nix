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
          echo "$p" >"$procs" 2>/dev/null || true
        done
        sleep 3
      done
    '';
  };
in {
  # Check runs share resource caps; they are never paused by a SIGSTOP queue.
  # The user manager's app.slice, where `systemd-run --user` units land.
  systemd.user.slices.app.sliceConfig = {
    CPUWeight = 20;
    IOWeight = 10;
    # Soft limit only: a hard MemoryMax next to the gate's freezing left the
    # kernel with "no killable processes" in a loop (journald at 210 MB/s).
    MemoryHigh = "10G";
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
