# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #110 merge commit on main (2026-11-19): E6 (PR #109)
  # plus a test-only fixture fix, so its CI run is green. Same runner bytes.
  revision = "7ad555a936efaa3b69e0729515d37019ef6dd952";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-NA2p75byK9Uhjbg/sUljUzZgC6Wdv3xih5NMh2VSil8=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "44484714233";
    sha256 = "1247a6c7b480b38d8d3c1a4ac17f8585b2376e6ae295f7c1530ac42ff626abd0";
  };
}
