# The one eve-deployments revision black runs: the agent-source toolchain
# (hosts/black/agent-source.nix) and the hosted runner bundle
# (hosts/black/hosted-runner.nix). eve-deployments is private and this
# repository is public, so no source is vendored or fetched here: each value
# pins bytes the operator provisions on black. Bump all of them together:
# runbooks/black-agent-source.md, "Bump the eve-deployments pin".
{
  # eve-deployments PR #112 merge commit on main (2026-11-19): PR #111
  # (owner-writable toolchain copies, so builds from the read-only Nix store
  # work) and PR #112 (a proxy's non-JSON error reply is transport loss).
  revision = "309c478f6fe6f4d15bee37ed9cecb0a5a00e9d8c";
  # NAR hash of `git archive <revision>` unpacked (`nix hash path`).
  sourceHash = "sha256-8A1T/Dhjt/VihFNM2RzK5fjXbUFU3xcALt74wC3r1T0=";
  # fetchNpmDeps of that tree's package-lock.json (`prefetch-npm-deps`).
  npmDepsHash = "sha256-I7qC4awVQ9naCwXzqFb2TEqjFMqo280DcrMpSgm/VRg=";
  # The CI run's `native-runner` artifact for the same revision.
  runner = {
    run = "44510882916";
    sha256 = "7dfbd41d04284eb384043b38a66f6296fd7410aa49f3aedaa003f3308aecbb83";
  };
}
