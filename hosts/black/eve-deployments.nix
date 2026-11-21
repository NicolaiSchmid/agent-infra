# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #116 merge commit on main (2026-11-21): guests default
  # to 256 MiB. Includes PR #115 (a guest crash ends its delivery with an
  # `ending` on `retire`, not the runner) and everything up to PR #113.
  revision = "a75ddbc7dac8c8ca91b780e2cd41b6d418a1d5d2";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-hlp1E1mqi9WAObo00P/b20Kyp5wI6gWBr8k31cW0kNk=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "44952790607";
    sha256 = "034a6659d3102f143dde81693f2a1bd4a7ab5b5ff653b50ef19522b74c2fbe75";
  };
}
