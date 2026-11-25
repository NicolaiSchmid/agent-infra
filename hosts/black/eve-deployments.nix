# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #129 merge commit on main (2026-11-25): the runner
  # serves protocol 3 runs on the protocol 2 path and refuses an unknown
  # protocol per run instead of exiting. Includes PR #127 (callJuneRequest,
  # a typed June call under the workflow's own key), PR #128 (a failed Eve turn commits `fail`, so June ends the run failed and
  # alerts; June #1531), PR #125 (hosted.json manifests, juneTools()), PR #124
  # (batched replay reads), PR #122 and #123 (flushed publication, restore by
  # digest), PR #120 (runner slots) and everything before it.
  revision = "fb4d9bf2da745f802adf72f7f90b4d6c303b295d";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-OqodFIoK62wnRCVm5cLiLgu38S+U0dYt9wxwrTlM1NI=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45580770312";
    sha256 = "4220d61111457de9580e4683478bf8498e0ec01936edd33aff3ed9ff9cb2edc2";
  };
}
