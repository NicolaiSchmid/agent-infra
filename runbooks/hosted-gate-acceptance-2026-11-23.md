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
