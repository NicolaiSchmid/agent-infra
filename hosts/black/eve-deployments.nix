# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #130 merge commit on main (2026-11-25): the builder
  # passes hosted.json `models` (platform models) and `runCostCap` (the
  # author's default cost cap per run) through to June. Includes PR #129 (the
  # runner serves protocol 3 runs on the protocol 2 path and refuses an
  # unknown protocol per run instead of exiting), PR #127 (callJuneRequest,
  # a typed June call under the workflow's own key), PR #128 (a failed Eve turn commits `fail`, so June ends the run failed and
  # alerts; June #1531), PR #125 (hosted.json manifests, juneTools()), PR #124
  # (batched replay reads), PR #122 and #123 (flushed publication, restore by
  # digest), PR #120 (runner slots) and everything before it.
  revision = "0bda7f5d509da4218514fe48d97ad24f398d00ea";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-tE3V1QiETwkczInGZbsmC6xx2DRnbx7E1fxBdCyu+xE=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45629162596";
    sha256 = "4220d61111457de9580e4683478bf8498e0ec01936edd33aff3ed9ff9cb2edc2";
  };
}
