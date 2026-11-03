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

Build only the route unit from a source based on the exact running system's
source (`dadec0dccd4fb3245f1dfe16d7d84d1456d132dd`) plus the reviewed
`hosts/black/routes.nix` delta from the gateway routing source. Do not build or
switch current main's global system: it includes undeployed phone work.
The unit attribute is
`nixosConfigurations.black.config.systemd.units."routes.service".unit`.
Root the resulting immutable unit closure on black. Run
`scripts/activate-june-routing.py dry-run --unit <store-unit>/routes.service
--backup <new-private-directory>`, then `apply` with the same arguments.
The helper checks non-command unit equality, saves the existing service
override, replaces only commands, and checks gateway table/key equality.
Failed apply restores the prior override. `rollback` restores it explicitly.
Do not rollback policy while a June table still claims the new hosts: first
restore the saved June table with its sole publisher drained.

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
production code/data unchanged. Future code/data import is a separate step:
the current 1 GiB / 1.5 CPU service cap is below the successful rehearsal's
4 GiB / 2 CPU cap and needs capacity assessment before migration.
