# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #123 merge commit on main (2026-11-23): artifacts are
  # flushed before they are published or reported (PR #122) and backed-up
  # bundles restore by digest (PR #123). Includes PR #120 (runner slots) and
  # everything before it.
  revision = "08d282ca63d5c2cdfcb9a2359c30e5ada5664ffa";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-fZ/FfwksfvtMGG60Ja4rkezs7SheeXELPlU4c9bQCjk=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "45189938676";
    sha256 = "9e71111e5d6dc65b304fb3054cee30f0d5fa51404b16f57e30df827488990639";
  };
}
