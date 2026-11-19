# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #113 merge commit on main (2026-11-19): a failed build
  # stays failed, `{"retry": true}` starts a new attempt, and only commits on
  # main are built. Includes PR #111 (owner-writable toolchain copies) and
  # PR #112 (a proxy's non-JSON error reply is transport loss).
  revision = "1df39aa2b67e28b8a26ab58fd0ea8da132895833";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-lgYQZ00nlQtmdMccb+jbAi1hKL0L/7Pw/33ksEFjBng=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "44559403471";
    sha256 = "7dfbd41d04284eb384043b38a66f6296fd7410aa49f3aedaa003f3308aecbb83";
  };
}
