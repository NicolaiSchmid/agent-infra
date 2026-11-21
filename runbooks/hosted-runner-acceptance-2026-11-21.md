# Hosted runner live acceptance on black — 2026-11-21

June prod, MODUS org (tenant `pn75wyqcx6fwhbym297ncrwkm58fmckp`), synthetic
agents and data only. Black runs eve-deployments `a75ddbc` (PR #116 merge
commit, including PR #115) since agent-infra PR #100 (merge commit
`638d7e7`). The checklist is "Acceptance for live" in June's
`.plans/2026-11-18-hosted-workflow-runtime.md`, amended as below. June dev
was not used: its Convex container was still restart-looping
(`RestartCount` 201 at 21:50Z, restarted again at 22:05Z).

All times are UTC. Item 6 is a partial pass; every other item passed.

## Switch (2026-11-21 ~22:00Z)

- Eve CI run 44952790607 for `a75ddbc` passed: native-runner, validate,
  agent-builder and gvisor.
- `runner.mjs` SHA-256 `034a6659…2fbe75` matched the artifact's
  `SHA256SUMS`. It was provisioned to
  `/var/lib/hosted-runner/releases/a75ddbc…/`, and the toolchain source
  (`sha256-hlp1E1mq…`) was added to black's store.
- The environment pin is unchanged: eve-deployments
  `scripts/fixtures/gvisor-config.json` and `src/target-artifact.ts` are
  identical between `1df39aa` and `a75ddbc`. The release JSONs were kept, and
  no custody needed reconciling.
- `nixos-rebuild build` at `638d7e7` changed neither `docker.service` nor
  `/etc/docker/daemon.json`. Dockerd and the Convex containers were not
  restarted: `convex-june-prod-backend-1` still reported
  `StartedAt 2026-11-19T10:28:55Z` afterwards.
- The runner and agent-source units of both deployments were stopped. Then
  `nixos-rebuild switch` ran. It exited 4 because
  `dbus-broker.service` reload timed out after 90 s. dbus-broker stayed
  active, the new generation is current, and the new units started.
- After the switch, both `hosted-runner-june-*` units were active on
  `releases/a75ddbc…/runner.mjs` and reported `Runner ready`. Both
  `agent-source-june-*` units listened with toolchain `sha256:e9e7705f…`.
  The prod source API answered 401 from the Convex container. No unit was
  failed: the earlier `agent-source-june-dev-gc` failure, a 404 from dev's
  Convex, was cleared by the switch.

## Release path

The agents `n21-accept`, `n21-hog` and `n21-quick` were pushed to `main` of
the june-prod agent-source repository over tailnet SSH (commit `130c032`).
Builds were requested on the source API. All three were built and reported
to June (`reported: true`). Then they were activated and installed with
June's operator CLI:

| Agent | Build | Digest | Release | Installation |
| --- | --- | --- | --- | --- |
| n21-accept | `ks843bjrcjwpc9tppzj1jcqka18jnp9r` | `sha256:c5289520…` | `g5827t7vbedt2gqzsg2qmrsd5x8jmd4r` | `kx8661qjzwap5yn10d9rh37xzd8jme6g` |
| n21-hog | `ks8e3s6qbj0xyta41cy7mddh8x8jmq5b` | `sha256:8f8fe35c…` | `g5866pvy2g16bp2hjg38g6q4hn8jnp86` | `kx88mvpbt3epv3v6acd2ywk9fn8jmc7t` |
| n21-quick | `ks81059v6w03b3y298924tj0bh8jm2q7` | `sha256:30f30b3c…` | `g5870vg2368nrctv95c2ae6r0x8jn78d` | `kx851thbs8j5dr7tmd1tx1zesd8jnga5` |

`n21-accept` uses a scripted model. It calls a June read through the call
ledger (`lookup`, key `n21-lookup`/0, `tools.search`), then a durable 60 s
timer (`nap`), then a step that stays in flight for 150 s with no external
write (`hold`). Finally it makes one model call through June's model
primitive.

## Results

| # | Item | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Built by black's agent-source builder and started manually | Pass | Table above; run `hd8emdxkgsryqf4fzwv9dy8gkn8jnj01` started 22:02:37 by `operator.ts start` |
| 2 | Guest runs under gVisor | Pass | Every guest has `HostConfig.Runtime=runsc`, `Memory=268435456`, `NetworkMode=none`, `ReadonlyRootfs=true` and image `node@sha256:c0a93797…`. `runsc --root /var/run/docker/runtime-runc/moby list` showed guest `de518e0b57ff` running (pid 870459) at 22:04:12. The host process is `gvisor_sentry` (`runsc-sandbox --platform=systrap --host-uds=open`) |
| 3 | One real model call through the MODUS gateway | Pass | Usage event `wd7bq5t916ptvd3yemfqdjk5xs8jm0w2` at 22:07:22.583: `runId` `hd8emdxk…`, provider `modus-gateway`, channel `background`, operation `agent`, model `cheap`, 18 in / 8 out tokens, funding source `k17y9xws8eefw722h0x2m2etpd8jh4av`. The answer was "N21 accept ok" |
| 4 | Timer across guests | Pass | `before-sleep` at 22:02:48 on guest `1f564932b4e4`. That guest exited 0 at 22:02:49 (run suspended, one live timer). `after-sleep` at 22:03:54 on a fresh guest, `de518e0b57ff`, started 22:03:50 |
| 5 | Kill during a step, no repeated ledger call | Pass | The `hold` step was dispatched at 22:03:57 on `de518e0b57ff` (fence 2). The runner was SIGKILLed at 22:04:12.61 and restarted by systemd at 22:04:42 (`Runner ready` at 22:04:43). The orphan guest was removed (exit 137), and a fresh guest, `18c3f742863c`, started at 22:04:44 (fence 3). `hold` completed once, on that guest (started 22:04:49.691). The call ledger holds one row: `n21-lookup`/0, attempt 0, fence 1, `succeeded`, completed fresh at 22:02:45.767 and never called again. No failure alert fired (`RestartMode=direct`) |
| 6 | Run completes, output readable | Partial | The turn finished at 22:07:22, and the guest exited 0 at 22:07:24. `operator.ts show` reads the reply "n21-accept finished. model cheap answered: N21 accept ok …", including the lookup, nap and hold results. The run stays `open`: Eve's session-timeout timer (`eve-wake`) is due at 2026-11-22T05:02:42Z, so the run is not `completed` yet. `/dashboard/runs/<runId>` was not opened (it needs a staff WorkOS session) |
| 7 | Crash isolation (eve-deployments #115, June #1455) | Pass | Run `hd85h0bkzghhhs2fdck0b1cwfs8jmgb5` (`n21-hog`) started at 22:10:39. Three runsc guests were each `OOMKilled` (exit 137) at 22:10:47, 22:10:54 and 22:11:01. The runner journal logged `Target delivery failed: guest-memory run hd85h0bk… fence 1/2/3`. The run ended `failed` with `failure {kind: guest-memory, attempts: 3}` at 22:11:01.660. The runner PID stayed 873016 throughout. It then served bystander run `hd81nqxy748xfcjr5zfts41fes8jm9vr` (`n21-quick`, guest `a4791c2d870a`, 22:11:04–22:11:10), whose model reply "N21 quick ok" is readable |

Out of scope by the amended checklist: a third-party tool with owner
approval, and killing the runner while an external write is in flight.

## Findings

- A manual start's input must be an Eve ingress message,
  `{"type":"eve.ingress","route":"session","body":{…}}`. The first start
  used plain JSON. Run `hd8axs1chnne93sgkp7c0z1rq98jm1vx` completed at once
  with the output `Invalid hosted run envelope: input must be an eve.ingress
  message for route session`. June's operator README does not name this
  shape.
- An Eve session run stays `open` after its turn until Eve's session timeout
  (about 7 h here). "Completed with output" in the plan therefore means the
  reply in output, not the run status. Re-check at 05:03Z whether the
  timeout ends the run `completed`.
- The `nixos-rebuild switch` exit code 4 came from dbus-broker's reload
  timeout, not from a hosted unit.

## Synthetic data left in June prod

- The installations `kx8661qj…`, `kx88mvpb…` and `kx851thb…` are paused.
- Runs:
  - `hd8axs1chnne93sgkp7c0z1rq98jm1vx`: `completed`, envelope error.
  - `hd8emdxkgsryqf4fzwv9dy8gkn8jnj01`: `open` until the session timeout.
  - `hd85h0bkzghhhs2fdck0b1cwfs8jmgb5`: `failed`.
  - `hd81nqxy748xfcjr5zfts41fes8jm9vr`: `open` until the session timeout.
- Delete the runs with `operator.ts delete <runId> --confirm=delete-run`
  once they have ended. Cancel the open ones first if they should not run to
  their timeout.
- The agent folders `agents/n21-*` remain in the june-prod source
  repository, which refuses deletes of `main` history.
