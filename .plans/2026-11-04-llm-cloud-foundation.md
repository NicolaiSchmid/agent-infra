# LLM cloud foundation
**Status:** in progress — implementation scoped 2026-11-04

Add a small OpenTofu foundation to the existing NixOS/SOPS repository. This slice
implements reproducible tools, offline validation, an Azure state/IAM bootstrap,
existing-account import configuration and protected Convex provider-key delivery.
It does not apply cloud changes, read existing secret values or activate a route.

The operator workflow and acceptance checks live in `runbooks/llm-upstreams.md`.
The upstream decision is recorded in the MODUS investigation pull request:
https://github.com/NicolaiSchmid/june/pull/978.

## Decisions

- Retain NixOS for hosts and SOPS/age for runtime secrets. Use plain OpenTofu
  configuration for cloud APIs; defer Terranix until it removes real duplication.
- Keep bootstrap and account state separate. Begin with interactive authorized
  bootstrap, then migrate to private versioned Azure Blob state. Record and test
  independent recovery access before production use.
- CI validates without cloud credentials. Only the manual main-branch plan job
  receives GitHub OIDC, with resource-group Reader and state lease permissions.
  No cloud apply identity or automatic deployment is added.
- Import the existing account with AzAPI and a pinned stable ARM API version.
  Never call listKeys. Require import-only and a clean follow-up plan before
  managing any existing settings. No invented account location/body is committed.
- Provider-key delivery consumes protected files and updates only supported names
  on fixed dev/prod gateway endpoints. No real credentials are read or delivered
  during implementation. Dev verification is required before production use.

## Deliberate deferrals

Actual subscription/group inventory, SOPS recovery recipients and credential
entry, cloud apply/import and runtime rotation need an operator session and real
reviewed configuration. Azure model deployments, Google projects/federation,
certificate-based inference auth and a Hetzner inference host follow in their
own resource-specific changes. No confidential client traffic is admitted by
this work; contractual and retention verification remains separate.

## Acceptance

Offline provider initialization and validation pass with committed lock files;
Nix flake evaluation and cloud-shell evaluation pass. Behavioral secret-delivery
tests cover wrong permissions, symlinks, target selection, rejected redirects,
quiet failures and dry validation. CI contains no secret-bearing artifact upload
or apply step. Open a reviewed PR; do not switch any running NixOS host.

## CI capacity correction, 2026-11-04

The first full Nix CI build exhausted the GitHub-hosted runner disk while
assembling Atlas's existing Pulumi bundle; Black and cloud validation passed.
Move the full Nix job to the existing organization Ubicloud standard-8 runner
class, matching June's Linux CI and this repository's documented runner policy.
Keep full host builds enabled; no host configuration or package pin changes.
