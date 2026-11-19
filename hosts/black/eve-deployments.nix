# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # E6, eve-deployments PR #109 merge commit on main (2026-11-19).
  revision = "2f407ae487c07dd7678b1c9869695b5dd9c070a6";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-idoOjeE7FwE4r1lnSGq2Cp7rUeIhO9r/hZNzCkD5T+k=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "44480146878";
    sha256 = "1247a6c7b480b38d8d3c1a4ac17f8585b2376e6ae295f7c1530ac42ff626abd0";
  };
}
