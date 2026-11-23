# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #125 merge commit on main (2026-11-23): hosted.json
  # manifests make protocol 3 builds reported with their manifest, and the
  # World's /tools export offers juneTools() with the describe and call
  # primitives (June's B1, june #1500). Includes PR #124 (batched replay
  # reads), PR #122 and #123 (flushed publication, restore by digest), PR #120
  # (runner slots) and everything before it.
  revision = "9038653333be8501d9b15be9c1cd544c991d56b2";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-KI2Iu0fvyxz3WLY7d08sgtBe6PlZ1e5L6yAGo+vISxM=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45202992740";
    sha256 = "c62586e9bb09f90a67382f97cc6b133447ddce295c531e1c89208df5af47cd7e";
  };
}
