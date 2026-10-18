# Atlas I/O priorities and build sweep

Two things keep atlas usable while agents and CI build on it
(`hosts/atlas/priorities.nix`, `hosts/atlas/build-sweep.{nix,sh}`):

- **BFQ and weights.** `atlas-io-scheduler.service` puts `vda` and `vdb` on
  the BFQ scheduler; without it `IOWeight` and `IOSchedulingClass` do
  nothing. t3code, Hermes, nginx, sshd and Tailscale run at
  `CPUWeight`/`IOWeight` 1000 (`io.bfq.weight` 181), the CI runners at 20,
  the sweep at 10 and idle class, everything else at the default 100.
- **Build sweep.** `atlas-build-sweep.timer` runs hourly at :25. It removes
  build output (node_modules, dist, build, out, .next, cargo target, ...)
  from worktrees whose threads are all settled, archived or deleted, and
  cargo target dirs from `workspace/`, the state tmp and `/tmp`. It only
  removes directories git ignores and tracks nothing in (outside git: cargo
  output with `CACHEDIR.TAG`), and skips anything a process works in or
  that was written in the last 120 minutes.

## Check

```bash
cat /sys/block/vd*/queue/scheduler                    # [bfq] on both
cat /sys/fs/cgroup/system.slice/t3code.service/io.bfq.weight   # default 181
cat /proc/pressure/io
systemctl list-timers atlas-build-sweep.timer
journalctl -u atlas-build-sweep -n 50                 # "remove <path>" per directory, free space before/after
```

## Operate

```bash
systemctl start atlas-build-sweep                     # run now
DRY_RUN=1 atlas-build-sweep                           # as root: log what would go, change nothing
systemctl stop atlas-build-sweep.timer                # pause until the next switch or reboot
```

`/var/lib/atlas-build-sweep/swept-worktrees.txt` lists worktrees already swept
and unchanged since; deleting it is safe and makes the next run look at
every settled worktree again.

The unit fails (and skips the worktree pass) when the t3code thread
projection in `statev2.sqlite` is unreadable or has not changed for a day.
That is what happens when a T3 Code update moves its state again: update
the query in `build-sweep.sh` rather than restarting the unit.

## Roll back

- **Scheduler only, now:** `systemctl stop atlas-io-scheduler` puts both
  disks back on `none`; `systemctl start` it to return to BFQ.
- **Weights only, now:** `systemctl set-property --runtime t3code IOWeight=100 CPUWeight=100`
  (and the same for the other units); a reboot or switch restores them.
- **Everything:** `nixos-rebuild switch --rollback`, or switch to the
  previous commit. The scheduler unit is stopped (disks back on `none`),
  the timer and weights go away. `/var/lib/atlas-build-sweep` stays behind
  and can be removed by hand. Removed build output is not restored; it is
  rebuilt by the next install or build.
