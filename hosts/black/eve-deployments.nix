# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #124 merge commit on main (2026-11-23): restore reads
  # records in pages of 16 and only unconsumed inbox rows, and the runner
  # answers a page above 4 MiB with 413 (phase 1 of June's replay compaction
  # plan). Includes PR #122 and #123 (flushed publication, restore by digest),
  # PR #120 (runner slots) and everything before it.
  revision = "8e233e67675f5def76b3c19873a1b5e568d79aa1";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-ErD/pyiRlHctOevULAgCRdBIhpuiZ2YaCLsiit1cM9g=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45199506655";
    sha256 = "2d5c6d820da9a246a5180fe3a2f7a91b3c2b31e97f922a1c63dca006b4ba7e98";
  };
}
