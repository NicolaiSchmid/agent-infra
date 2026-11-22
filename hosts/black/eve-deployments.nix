# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # NOT MAIN: eve-deployments integration/hosted-gate-2026-11-23 (draft PR
  # #121), main 01189cc plus PRs #119, #118 and #120 unmerged, for the
  # 2026-11-23 live gate tests only. Replace with the merged main revision.
  revision = "0789c898335e8620dc285d8b050e7c28b33527c5";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-osUUcvZauTw/z6AFZagj3uiA87ke6wUsI+Du0mWDEw8=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45082074364";
    sha256 = "dc60978a9b29be6c6924954aa9aa6ae871c4721087b3431f6bcc662631b5990c";
  };
}
