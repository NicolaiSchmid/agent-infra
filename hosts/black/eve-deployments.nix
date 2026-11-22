# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #117 merge commit on main (2026-11-22): the runner
  # measures guest CPU, memory and network for June's usage ledger. Includes
  # PR #116 (guests default to 256 MiB) and everything before it.
  revision = "01189cce608c498e935c019b707f3978acef331a";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-JXYjNcVMG3jjVjvLXO0usEp94mqIDBDtXvR5H4R8Xws=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45054018189";
    sha256 = "04822cb3d75d2ebf92e22258b395243898a9248bed0c4b9281273f622e37eff9";
  };
}
