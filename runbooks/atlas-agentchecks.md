# Atlas agent checks slice

Agents run their checks (tsc, eslint, vitest, `next dev`/`next build`) inside
`t3code.service`, next to the server and every session. `agentchecks-mover`
(`hosts/atlas/agentchecks.{nix,sh}`) moves them out every 2 seconds. Each
matching process, with its existing descendants, goes into its own transient
`agentcheck-<pid>.scope` in `agentchecks.slice`. Later forks (vitest
workers, `next-server`) start in that scope.

| Unit | CPU/IO weight | Memory |
|---|---|---|
| `agentchecks.slice` (beside `system.slice` and `atlas.slice`) | 100 | high 28G, max 30G, swap 8G |
| each `agentcheck-<pid>.scope` | | max 10G, swap 2G; `OOMPolicy=stop` |

The mover also raises each moved process's `oom_score_adj` to 500. When the
whole host runs out of memory, the kernel then kills a check, which can be
re-run, before an agent session or a Convex backend. It never signals a
process itself.

There is no holder unit. The setup before 2026-10-21 kept every check in one
`sleep infinity` service. When one check was OOM-killed, systemd stopped the
holder and its cgroup went away, so every later move failed with ENOENT and
the holder stayed `failed`. A scope only lives as long as its check.
`CollectMode=inactive-or-failed` drops it after the check exits, including
after an OOM kill.

## Check

```bash
systemctl status agentchecks-mover --no-pager
journalctl -u agentchecks-mover -n 20            # "moved <pid> (<n> processes): <command>"
systemd-cgls -u agentchecks.slice --no-pager | head -40
systemctl status agentchecks.slice --no-pager    # Memory: current / high / max
cat /sys/fs/cgroup/agentchecks.slice/memory.events   # high / max / oom_kill counts
cat /sys/fs/cgroup/agentchecks.slice/memory.pressure
```

An agent check that exits with 137 was OOM-killed. Run
`journalctl -k | grep -i oom` to see whether its own scope hit 10G (the
`oom-kill` line names `agentcheck-<pid>.scope`) or the slice hit 30G. A
single unbounded `vitest run` uses about 1.5–2.4G per worker, with 11 workers
on 12 cores, so give it `--maxWorkers=4`.

## Operate

```bash
systemctl stop agentchecks-mover     # checks stay in t3code from now on; moved ones stay put
systemctl start agentchecks-mover
systemctl set-property --runtime agentchecks.slice MemoryMax=34G   # until the next switch or reboot
```

Do not `systemctl stop agentchecks.slice`. That kills every check in it.

## First deploy (replaces the hand-made units)

The hand-made units are transient: `/run/systemd/transient/agentchecks-*`,
plus `set-property` drop-ins in `/run/systemd/system.control/agentchecks.slice.d/`.
Both take precedence over the units this repository installs, so remove them
before switching. As root on atlas:

```bash
systemctl stop agentchecks-mover.service            # the transient /root/agentchecks-mover.sh
systemctl reset-failed agentchecks-holder.service   # failed since 2026-10-20 22:29
rm -r /run/systemd/system.control/agentchecks.slice.d
systemctl daemon-reload
systemctl cat agentchecks-mover.service agentchecks-holder.service   # both: "No files found"
```

Then switch (README, "Rebuild atlas") and verify with the Check commands
above. `/root/agentchecks-mover.sh` can be deleted once that is done.

## Roll back

- **Mover only, now:** `systemctl stop agentchecks-mover`. Scopes that
  already exist run to completion.
- **Everything:** `nixos-rebuild switch --rollback`. The mover and the slice's
  limits go away. Running scopes keep their own 10G cap until their checks
  exit.
