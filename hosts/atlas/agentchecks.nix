# Agent checks (tsc, eslint, vitest, next) in their own slice; see
# agentchecks-mover.sh and runbooks/atlas-agentchecks.md.
#
# Until 2026-10-21 this was set up by hand: a transient agentchecks.slice at
# 10G high / 12G max / 2G swap and CPU weight 20, and a `sleep infinity`
# holder service whose cgroup a mover filled with every check. On 2026-10-20
# at 22:29 the kernel OOM-killed a check, systemd stopped the holder
# (OOMPolicy=stop) and its cgroup went away; from then on nothing was moved,
# and for the hours before every check crawled against the 10G MemoryHigh
# (tsc at ~1 % CPU, memory PSI ~95 % full) or died with exit 137. Ten agent
# lanes need more than 12G, and an unbounded `vitest run` alone (11 workers
# on 12 cores) reaches ~17G.
{pkgs, ...}: let
  mover = pkgs.writeShellApplication {
    name = "agentchecks-mover";
    runtimeInputs = with pkgs; [coreutils systemd];
    text = builtins.readFile ./agentchecks-mover.sh;
  };
in {
  # A top-level slice, beside system.slice (where t3code and its agents run,
  # weight 100) and atlas.slice (CI and containers, weight 20). Equal weight
  # with system.slice: an agent waits on its checks, so they should not lose
  # to CI. atlas has 50G RAM and 25G zram swap. atlas.slice may take up to 28G
  # and t3code's sessions, Convex local backends and the system ~10-13G, so
  # the two caps overcommit RAM on purpose: both rarely peak at once, and
  # when they do the mover's oom_score_adj makes a global OOM pick a check.
  # MemoryHigh sits just below MemoryMax: throttling is what turned the old
  # slice into hours of D state, so it should only start right at the wall.
  systemd.slices.agentchecks = {
    description = "Agent checks moved out of t3code";
    sliceConfig = {
      CPUWeight = 100;
      IOWeight = 100;
      MemoryHigh = "28G";
      MemoryMax = "30G";
      MemorySwapMax = "8G";
    };
  };

  systemd.services.agentchecks-mover = {
    description = "Move agent checks out of t3code into agentchecks.slice";
    wantedBy = ["multi-user.target"];
    after = ["t3code.service"];
    environment = {
      # Per check (one scope each): three runaway checks fill the slice, one
      # cannot. Room for a tsc (~2.5G), a next dev/build, or vitest with ~5
      # workers; an unbounded vitest is OOM-killed on its own (exit 137).
      SCOPE_MEMORY_MAX = toString (10 * 1024 * 1024 * 1024);
      SCOPE_SWAP_MAX = toString (2 * 1024 * 1024 * 1024);
    };
    serviceConfig = {
      ExecStart = "${mover}/bin/agentchecks-mover";
      Restart = "always";
      RestartSec = 5;
      # A 2-second scan; it must keep up while the host is saturated.
      CPUWeight = 1000;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
}
