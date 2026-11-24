# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #127 merge commit on main (2026-11-25):
  # callJuneRequest, a typed June call under the workflow's own key. Includes
  # PR #128 (a failed Eve turn commits `fail`, so June ends the run failed and
  # alerts; June #1531), PR #125 (hosted.json manifests, juneTools()), PR #124
  # (batched replay reads), PR #122 and #123 (flushed publication, restore by
  # digest), PR #120 (runner slots) and everything before it.
  revision = "7650e12e11f02cb8d41cf426a702583f36f55ffb";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-ldFgJnF7WxrX+OqHE05qhwMHgQlHlwBkEa0irSzD/jc=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45512293443";
    sha256 = "f621fe101049992dbe9e751dcbbf22464426092797e7fca892c2f7f909a83d9c";
  };
}
