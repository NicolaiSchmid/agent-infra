# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #120 merge commit on main (2026-11-23): the runner
  # runs up to its configured slots in parallel (June G6). Includes PR #119
  # (a workflow run completes after its turn), PR #118 (polling docs) and
  # PR #117 (guest usage measurement). Same tree as the live gate build
  # 0789c89 (runbooks/hosted-gate-acceptance-2026-11-23.md).
  revision = "8482ee3556ab63e5bbf075f32335eaee7e4c0b04";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-osUUcvZauTw/z6AFZagj3uiA87ke6wUsI+Du0mWDEw8=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45163113133";
    sha256 = "dc60978a9b29be6c6924954aa9aa6ae871c4721087b3431f6bcc662631b5990c";
  };
}
