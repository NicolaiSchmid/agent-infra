# Prepare the empty June production destination

The parent accepted the existing persistent `convex-june-prod-backend-1` as
June's destination on 2026-11-03. It is separate from the removed disposable
rehearsal. Authenticated system queries returned no components, API functions
or schema; storage was empty and HTTP actions returned 404. This change adds
only the production route ownership. It deploys no application or data.

Keep the gateway project and key unchanged. Wait for its evidence publication
from the gateway activation evidence pull request (#952) to finish before
changing policy. Snapshot its table, rendered routes, ACME, key, override and
system profile privately immediately before activation. Back up June's SQLite
with the online SQLite backup API and retain its credentials and empty storage
privately; never print credentials or commit backups.

The route policy was activated on 2026-11-03 through a hand-made override of
`routes.service`, removed on 2026-11-10; route policy changes now ship with
`nixos-rebuild switch`. Do not roll back policy while a June table still
claims the new hosts: first restore the saved June table with its sole
publisher drained.

The new `june` project accepts exactly `june.convex.modusservice.com` and
`june-http.convex.modusservice.com`, targeting only `june-prod`. Generated
hosts and every June development reservation remain protected. Its new key
must go only to a dedicated main-only GitHub environment. Never reuse the
gateway key. Registry activation alone exposes no new route; publication
creates public API and HTTP routes immediately and requests individual
HTTP-01 certificates. Recheck inertness just before that first publication.

DNS uses explicit DNS-only A/AAAA records. After publication verify trusted
TLS, `/version`, harmless WebSocket connection/read behavior and HTTP 404 over
both families. Keep clients, origins, environment, webhooks, schedules and
production code/data unchanged. Capacity: `runbooks/june-production-capacity.md`.

## Checked operator sequencing

On 2026-11-03 a local DNS lookup returned a cached negative answer, but the
operator's shell continued to the publisher PR merge. The first check did
not pass. Public Cloudflare DNS answers, target inertness and fresh snapshots
were verified while the publication was still queued, before its PUT.

Use `scripts/checked-routing-step.py` to gate any future merge, PUT or workflow
release on explicit readiness commands. Pass argument arrays, never shell
command strings; credentials remain in private files or environment variables.
Each readiness command must itself return nonzero on a failed assertion. For
example, run the private identity/backup preflight over SSH as `--check`, then
pass the exact-head `gh api` merge as `--action`. The helper invokes every
check with `check=True` and reaches the action only after all checks pass.
Do not rely on a semicolon chain or shell `set -e` across conditional/pipeline
contexts. The controlled-failure test executes a failed readiness process and
proves that the mutation marker is never created; the success test pins order.
