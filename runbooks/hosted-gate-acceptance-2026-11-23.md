# Hosted workflow gate: live tests on black, 2026-11-23

These are the live tests before merging the hosted workflow gate. The pull
requests under test:

- June: G3 #1475, G5 #1474, G6 #1477 and G7 #1478.
- eve-deployments: run end #119, the polling doc #118 and runner slots #120.
- agent-infra: slot counts #102.

The agents and data were synthetic. All times are UTC. june-dev could not
take the June code, so the tests that need it did not run (see "June dev").
Everything else ran in June prod's MODUS org (tenant
`pn75wyqcx6fwhbym297ncrwkm58fmckp`), on June prod's current main code, as on
2026-11-21. No June branch was deployed to June prod.

## Revisions

| Repository | Integration | Contents | CI |
| --- | --- | --- | --- |
| eve-deployments | `0789c89` (draft #121) | main `01189cc` with merge commits of #119 `03e87e2`, #118 `da8e22c` and #120 `1217125`; no conflicts | run 45082074364: validate, gvisor, native-runner and agent-builder green. `runner.mjs` SHA-256 `dc60978a…5990c` matches `SHA256SUMS` |
| agent-infra | `171ebf1` (draft #104) | #102 head `d33429e` with main merged in, plus the pin bump to `0789c89` (`sourceHash` `sha256-osUUcvZa…`, `npmDepsHash` unchanged, runner run 45082074364) | green |
| June | `806247e` (draft #1483) | main `630dd53` with #1475 `7f8d1d6`, #1474 `9d419de`, #1477 `56cd6f0` and #1478 `7932c39` merged in that order | green |

June's merge resolution:

- It keeps #1474's `by_installation_status`, drops #1478's `by_installation`,
  and reads `by_installation_status` in `operations.list`.
- In `runs-content.tsx`, the staff `QueuePanel` sits above #1478's view
  without an installation.

A side effect of dropping the index: a list for one installation is ordered by
status first, then by creation time (`desc` over `[installationId, status]`).
It is no longer strictly newest first. Keep this in mind when the real merge
resolves the conflict.

The environment pin did not change. `package-lock.json`,
`scripts/fixtures/gvisor-config.json` and `src/target-artifact.ts` are the same
in `01189cc` and `0789c89`, so the release JSONs stayed.

## Switch (2026-11-22 23:26–23:28Z)

- The runner bundle went to `/var/lib/hosted-runner/releases/0789c89…/`. The
  toolchain source went into black's store as
  `eve-deployments-0789c898335e`, and the toolchain was built and rooted
  (`agent-source-toolchain-0789c898335e`).
- `nixos-rebuild build` at `171ebf1` left `docker.service`, its drop-ins and
  `/etc/docker/daemon.json` unchanged.
- Before the switch, black was on generation `bacq4g5p…`, saved to
  `/root/hosted-runner/pre-gate-2026-11-23-system`.
- The four runner and agent-source units were stopped, with no guests running.
  Then `nixos-rebuild switch` ran. It exited 4 for two reasons:
  - the known `dbus-broker` reload timeout;
  - `agent-source-june-dev-gc` failing on a 404 from june-dev's Convex.
    june-dev runs code from before J9 and has no `/hosted-runs/builds/referenced`.
    The unit fails again every day until june-dev runs current main.
- After the switch:
  - Both runners were on `releases/0789c89…/runner.mjs`, described as
    `slots 2` (prod) and `slots 1` (dev), with `TasksMax` 128 and 64.
  - Both logged `Runner ready`, then `Runner slots unavailable on the control
    plane; one delivery at a time`. That is #120's fallback against a June
    without `poll`.
  - Both agent-source units listened with toolchain `sha256:271867f5…`.
  - June prod's source API answered 401 from its Convex container.
- dockerd and `convex-june-prod-backend-1` were not restarted (`StartedAt`
  stayed 2026-11-19T10:28:55Z).

## June dev

june-dev cannot take a deploy. At the start, the
`convex-june-dev-backend-1` restart count was 416. The container is OOM-killed
at its own 768 MiB limit every few minutes. It runs hosted code from before J9
(no `installations` or `builds` modules) and has no hosted rows.

`convex deploy --dry-run --typecheck=disable` of the June integration failed
twice with 502, at `evaluate_push` and at `start_push`. The kernel logged
`Memory cgroup out of memory: Killed process (convex-local-ba)` at 23:19:45,
23:20:23 and 23:20:35Z, and the restart count went from 418 to 420 during the
push. The push itself kills the backend. As Nicolai Schmid instructed, the
June-code tests stopped there.

## Agents and releases (June prod)

The agents `g23-end`, `g23-hold`, `g23-approve` and `g23-poll` were pushed to
the june-prod source repository (commit `3a5626c`). Black's builder built them
with the new toolchain, and they were reported to June. Then they were
activated and installed by the operator CLI from main:

| Agent | Release | Installation |
| --- | --- | --- |
| g23-end | `g58ak98rfp9v7crdvdpcmcevb98jqb8j` | `kx8cybhtpsnp8sea2b522cf9xs8jppzj` |
| g23-hold | `g58cczhjewn00cnvhhb7rk3wrd8jpeme` | `kx8d61jypcttdndgbkv272btch8jq4ax` |
| g23-approve | `g587gbm35wtsyqdg7cy8yashj58jpy9n` | `kx887sz6zqnspf8676mzdyhk118jq3n7` |
| g23-poll | `g58fx38q9rd0xpa22heej0x46d8jqczt` | `kx8bjbcyg80xz3whsts4jhng118jpe26` |

## Results

| Journey | Result | Evidence |
| --- | --- | --- |
| a. Run end (decision 6, eve #119) | Pass | Run `hd87apk4rh21dckvz7fbr6pxfs8jqq80`: started 23:29:27, one delivery (fence 1). Model usage event `wd77cgcq…` (`modus-gateway`, `cheap`, 18 in / 8 out tokens) at 23:29:36.6. The run was `completed` at 23:29:37.8 with no live timer. `@result` was `{"status":"ended","outcome":"completed","turn":{"turnId":"turn_0","status":"settled","outcome":"completed"}}` |
| a. Approval wait | Not shown | The member's approval rules allowed `june_google_drive … api_write`, so run `hd82faf16dd91nhh8a2jd9nb0n8jpvsc` had no approval to wait for. Its call `g23-approve-folder`/0 `succeeded` at once, and the run completed after its turn (another run-end pass). It created one real, empty Drive folder `g23-gate-synthetic-do-not-approve` (id `1LEZk3kcAO7P7J6cwQxCvasBfdItfof1P`), which is still there. The open-while-pending state is covered only by #119's session integration test in CI |
| f. Polling (decision 10, eve #118) | Pass | `executeJuneTool` from a `turn.started` hook works: the ledger key is the derived `eve:<hash>` form, so the fallback path was not used. Nothing new: run `hd8at8nncw4f0yyv7rsyzpfnes8jpd35` got `{"newItems":0}` from June, the turn was cancelled, and the run ended `completed` with turn outcome `cancelled`. It had no model usage event and no call intent. New work (customization `newItems: 2`): run `hd83edwjwk7yh9nysfvytm4bdd8jpjwp` went ahead with one model call (`wd74vatc…`) and ended `completed`/`completed` |
| d. Runner slots against June without `poll` (eve #120, agent-infra #102) | Pass (fallback) | Three `g23-hold` runs (40 s step) were started within 0.8 s: `hd8fqt7a…`, `hd83y478…` and `hd88tk6g…`. They ran one at a time, oldest first, on at most one guest. They completed at 23:33:20, 23:34:14 and 23:35:06 |
| b. G3, results recorded after cancel (June #1475) | Not run | Needs the June code; june-dev is unusable |
| c. G5, schedule modes (June #1474) | Not run | Same reason |
| d. G6, June queue and parallel slots, staff queue view (June #1477) | Not run | Same reason. Only the runner-side fallback above ran |
| e. G7, installation and run on usage lines (June #1478) | Not run | Same reason. On main code, the usage event above carries `runId` and no `installationId` or `hostedRunId`, as expected |

Each run left no guest behind: `runsc list` was empty after every run.

## Cleanup (2026-11-22 23:36Z)

- The seven g23 runs were deleted with
  `operator delete --confirm=delete-run --operator=g23-gate`, and purged.
  `hostedRuns`, `hostedRunAuthorities` and `hostedRunCustodies` are back at
  their baseline counts (55, 182 and 182).
- The four installations are paused and their releases retired. The operator
  has no way to delete either. The agent folders stay in the june-prod source
  repository, which refuses deletes of `main` history.
- No baseline row of `hostedInstallations`, `hostedReleases` or `hostedRuns`
  is missing or changed.
- The 2026-11-21 runs `hd8emdxk…` (revision 129, fence 4) and `hd81nqxy…`
  (revision 37, fence 2) are still `open`, as before, with one timer each,
  `eve-wake`, due 2026-11-23T04:02:42Z for `hd8emdxk…`. They pin old
  artifacts, so per #119 they keep the old behaviour.
- Black: the same 27 containers as before, no gVisor guest, 38 GiB free. The
  only failed unit is `agent-source-june-dev-gc` (see Switch).
- Black stays on agent-infra `171ebf1`, the integration pin, until the merged
  main revision is switched.

## Not verified

- G3, G5, G6 (June queue, parallel deliveries, staff queue view) and G7. Each
  needs a june-dev that survives a deploy, or the merged code on June prod.
- An approval wait keeping a run open, live.
- The pre-existing open runs' `eve-wake` firing on the new runner after
  04:02Z.
- Screenshots of `/dashboard/runs` and Usage: no staff session.

## June journeys after merge (2026-11-23 10:26–10:53Z)

G3, G5, G6 and G7 ran on June prod after the June pull requests merged. The
production build of June main `3f3cbe9` (G7, the last of them) reported
success at 10:35:46Z. June prod then served `hostedRuns/runner:poll`, the
schedule `mode` and the usage fields `installationId` and `hostedRunId`.
G3, G5 and G6 had already deployed with their own merge commits (09:13,
09:26 and 10:06Z). Black was not switched: it stayed on the integration pin
above, with `0789c89` and two slots for June prod. The data was synthetic and
everything ran in the MODUS org. Raw logs are in `/tmp/live-june-a88e9a7f/` on
Atlas.

### Runner slots against June with `poll`

- June prod's runner kept its process from the switch. It had logged the
  fallback line once at 23:27:58Z, and the runner logs nothing when `poll`
  starts to work. Proof that it polls: the `hostedRunners` row
  `black-june-prod`, `slots: 2`, was created at 10:06:41Z, seconds after
  G6 reached June prod.
- After the G3 runner kill below, the restarted runner logged only
  `Runner ready` (10:40:29Z), with no fallback line.
- june-dev's runner has been `failed` (`start-limit-hit`) since 01:30Z. It
  exits with `Runner stopped with startup, ownership or cleanup failure`
  against june-dev, which runs code from before J9. It was left alone.

### Agents

Four agents were committed through the June prod source API (`POST
/v1/agents/<slug>/commits`) and built by black's builder:

- `j23-call`: one June code call that waits 20 s.
- `j23-hold`: 40 s, then one model call.
- `j23-long` and `j23-skip`: 75 s each, no model call.

A fifth, `j23-end`, was a copy of `g23-end` with one model call. A retired
release cannot be activated again, so the `g23-*` releases could not be
reused. June has one installation per agent and tenant, so G5 needed two
agents.

| Agent | Installation | Release |
| --- | --- | --- |
| j23-call | `kx8ba1x5fmdhb83ct1p0vmtgs18jsegm` | `g587t1my…` (setTimeout version), then `g584tvr1acbc5xf8tdrrr0dkvx8jrxj3` |
| j23-hold | `kx823bvj6yz663ahjfx43fx6z58js42t` | `g58ac0zeshnpa1279rbwzb2rs58jsk91` |
| j23-long | `kx83mvf7kpqh5rfg6205rgq0g58jsp4k` | `g58d76hmzt5y4s9qtsdyxg08z58jsnpb` |
| j23-skip | `kx89hnn3jy6ga5am7bg751qdeh8js0pe` | `g5834p3agavhcwm932qx262sbx8jsx0h` |
| j23-end | `kx84e4h55187pyyxchyhsexqwx8js2yz` | `g58e9yh607pz0avxz4h4gwb4r98jsmh7` |

June's code runtime (QuickJS) has no `setTimeout`. The first `j23-call` run,
`hd80hyfb…`, therefore recorded its call as `failed` at once (`'setTimeout'
is not defined`) and did not test G3. The agent was changed to busy-wait
inside the 55 s program limit.

### Results

| Journey | Result | Evidence |
| --- | --- | --- |
| G3, cancel during a June call (decision 7) | Pass | Run `hd894da6bpjvckj9ag54p8an218jsrx8`. Call `j23-call-slow`/0 was claimed at 10:38:50.2 and seen `started` at 10:38:50.50. `cancel` returned at 10:38:50.77. The guest's request ended with `499` at 10:38:50.92 (Convex HTTP log). June's action kept running: by 10:39:11 `show … calls` had the call `succeeded`, fence 1, attempt 0, result `{"waitedMs":20000}`. The run is `cancelled` with no authority and no custody, and its authority `g987r6j6…` is `retired: true`. A later call with that run's token could not be sent from outside: the token stays on the runner. That refusal is covered by `tool-calls-after-cancel.test.ts` in CI |
| G3, runner kill during a June call | Pass | Run `hd8adt4529h1xte2ttphj6gq6d8jsa2j`. The call was `started` at 10:39:58.54. The runner was SIGKILLed at 10:39:58.58, as in the 2026-11-21 acceptance, and systemd restarted it at 10:40:28. The run was delivered again at fence 2 on the new runner generation and `completed` at 10:40:38. The ledger holds one row, `succeeded` at fence 1, so the redelivery replayed it and the call never ran again. Both custodies are `clean` |
| G5, schedule modes (decision 8) | Pass | Every-minute cron on both installations from 10:45:00 to 10:48:06Z, when both were paused. Brute force admitted `hd8ec587` at 10:45, `hd86f41m` at 10:46, `hd832kj2` at 10:47 and `hd864jer` at 10:48. Two of them were open at the same time at 10:46 and at 10:47. Skip admitted `hd8ata2w` at 10:45. At 10:46 it logged `hosted_installation_tick_skipped` `{installationId: kx89hnn3…, at: 1795430760000, openRunId: hd8ata2w…}`. After that run completed (10:46:3x), it admitted `hd831pzh` at 10:47. At 10:48 it skipped again with `openRunId: hd831pzh…`. Nothing was admitted after the pause. The event comes from `convex logs` (`admitScheduled`), not `docker logs` of the backend container |
| G6, parallel slots and the queue (decisions 11–13) | Pass | `j23-hold` runs `hd8ba8p2…`, `hd87daem…` and `hd825swh…` were started within 0.7 s, at 10:41:33Z. From 10:41:38 to 10:42:25 there were two gVisor guests, two live custodies and the third run waiting. The staff queue view (`hostedRuns/dashboard:queue`, run as a staff identity) read `waiting=1 live=2 inUse=[2]`. The first two completed at 10:42:28.7 and 10:42:28.8. The third was claimed at 10:42:30.9 and completed at 10:43:23. The view then read `waiting=0 live=1 inUse=[1]`. Oldest first held. No guest was left |
| G7, installation and run on usage lines (decision 14) | Pass (queries) | Every `usageLedger` line of the 13 test runs carries `installationId` and `hostedRunId`: `gvisor`/`hosted_runtime`, `june`/`execute` and `modus-gateway`/`agent` (`cheap`, channel `background`). In `usageDaily`, `hostedRunId` is null where several runs meet (the three `j23-hold` runs), as designed. `j23-end` run `hd89gj62g4yvp5y15h0qgq1ag98jre2a` was its installation's only run that day. Its rows keep the run in `usage/reads:workspaceAdmin`, read as an admin identity: 12 rows with `hostedRunId: hd89gj62…`, and `workflows` names all five agents. `ledger-usage.logic.ts` links such a row to `/dashboard/runs/<runId>` |

### Side effects

- Billing: all 117 `usageLedger` lines written between the baseline
  (10:32:55Z) and 10:52Z were checked. The 111 hosted lines all belong to the
  13 test runs. The model cost was 4 requests, 69 input tokens and 40 output
  tokens through the MODUS gateway. The other 6 lines are `codex`
  `soul_analysis` in another workspace, unrelated to the test.
- Each run left no guest behind. At the end black had 0 gVisor guests and 21
  containers, the same as before. `convex-june-prod-backend-1` was not
  restarted (`StartedAt` 2026-11-23T01:19:04Z, before this test). Black's
  disk was at 98 % (20 GiB free) before and after.
- The 2026-11-21 open runs: between #105's cleanup and this baseline, their
  `eve-wake` had fired on the new runner. `hd8emdxk…` moved from revision 129,
  fence 4 to revision 135, fence 5, and `hd81nqxy…` from 37, fence 2 to 43,
  fence 3. Both are still `open`, and their next wakes are due on
  2026-11-24. This test left their rows, timers and calls unchanged.

### Cleanup (10:51–10:53Z)

- All five installations are paused, and the six releases created here are
  retired.
- The 13 test runs were deleted with `operator delete --confirm=delete-run
  --operator=j23-journeys` and purged. Against the 10:32:55Z baseline:
  - `hostedRuns` 55, `hostedRunAuthorities` 184, `hostedRunCustodies` 184 and
    `hostedRunTimers` 51 are back at baseline, with no baseline row missing
    or changed.
  - `hostedRunCalls` keeps only its five earlier rows.
  - Beyond the baseline, there are 5 more installations and 6 more releases,
    which the operator cannot delete.
- The agent folders `j23-*` stay in June prod's source repository, which
  refuses deletes.
- The admin key file on Atlas and the clone on black were deleted.

### Not verified

- Screenshots of `/dashboard/runs` and of the Usage page's Workflow column:
  there is no staff browser session (WorkOS login). Only the queries behind
  them were read.
- A call with a retired run token: the token never leaves the runner. Only
  the retired authority and the guest's 499 were shown.
- Whether the fence-2 redelivery got `outcome: replayed`: the ledger row
  count and attempt show the call did not run again, but the guest's reply
  was not decoded.
