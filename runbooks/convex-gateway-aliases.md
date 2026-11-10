# Activate the gateway aliases after parent review

Prepare the four gateway aliases without moving June or replacing inference.
The MODUS/June routing preparation pull request (#945) owns the candidate map
`artifacts/domain-routing/gateway-routes.json`. It remains offline.

## Offline rehearsal

Set `MODUS_CHECKOUT` to an owned checkout of the routing preparation branch.
From agent-infra:

```sh
node --test hosts/black/routes/*.test.ts
nix eval --json .#nixosConfigurations.black.config.assertions --apply 'xs: builtins.filter (x: !x.assertion) xs'
registry_file=$(nix build .#nixosConfigurations.black.config.system.build.routesRegistry --no-link --print-out-paths)
node hosts/black/routes/rehearse.ts --registry "$registry_file" \
  --table "$MODUS_CHECKOUT/artifacts/domain-routing/gateway-routes.json" \
  --project modus-gateway > /tmp/gateway-traefik-rehearsal.json
```

Expect both inference routers and four exact gateway routers, using only
`modus-gateway-{dev,prod}-{cloud,site}@docker`, `websecure` and `letsencrypt`.
The apex, control host, generated deployment hosts and June aliases remain
reserved. `june-dev` already serves an independent black instance. Namespace
wildcards, nested wildcards and cross-project claims are rejected.

This rehearses HTTP-01 configuration, not certificate issuance. Traefik uses
port 80 and an individual certificate per host. Issuance needs DNS and a router;
issuing new-host certificates now would cross the parent-review boundary.
No wildcard DNS, wildcard certificate or DNS API credential is needed.

## Evidence and backups on 2026-11-03

Executor's Cloudflare connection confirmed existing deployment and inference
DNS-only A/AAAA records match the DNS repository. New gateway aliases are
absent. The DNS change appends only four names using the existing gateway
addresses. An offline forward/reverse rehearsal preserved all original bytes.
The DNS PR's OctoDNS dry-run is the provider-backed diff; merge deploys it.

Read-only SSH inspection confirmed deployed HTTP-01 settings and Docker
services: API/WebSocket on container port 3210, HTTP actions on 3211.
Trusted HTTPS `/version` worked for both existing gateway API hosts over IPv4
and IPv6. Both WebSockets upgraded, then authenticated using each environment's
admin key locally on black. A read-only `gateway:authorize` subscription for
a synthetic missing hash returned `QueryUpdated(null)` in both environments.
No credential or customer data was printed. New-host checks await activation.

Private backups on black are in
`/var/lib/client-data/backups/convex-routing-936258ad/`: `routes-before.json`,
`rendered-before.yml`, `acme-before.json`, `system-before`, all mode 0600.
ACME state contains private keys; never print or commit it. Refresh backups
into a new timestamped directory immediately before activation.

## Activation after parent review

1. Merge the infra PR after checking its exact head and deploy it with
   `nixos-rebuild switch`. Confirm routes health and unchanged inference. The allowlist alone creates
   no aliases or certificates.
2. Merge the reviewed DNS PR. Its `DNS Sync` workflow publishes records.
   Check that the dry-run adds only the intended records, then verify every
   new A/AAAA answer and port 80 over both address families.
3. Follow the MODUS publisher handover runbook. Securely snapshot the current
   routes using `push-routes.ts --snapshot --backup <new-private-file>`.
4. Publish with `push-routes.ts --apply --file
   artifacts/domain-routing/gateway-routes.json --backup <new-private-file>`.
   Load the project key from its secure store, never a command-line literal.
   This creates routers and triggers individual HTTP-01 issuance. Inspect
   `journalctl -u routes` and `docker logs traefik-traefik-1` on black.
   Verify trusted TLS for each alias. Certificates cannot be required before
   publishing the router that requests them.
5. Check API `/version`, a real authorised WebSocket subscription, HTTP action
   behavior and authenticated inference streaming in both environments over
   both address families. Keep clients, backend origins, June and the Vercel
   dashboard unchanged.

## Rollback

Disable the GitHub publisher and wait for a running publication to finish.
Restore the saved table through `push-routes.ts --apply --file <saved-table>
--backup <new-file>`, then verify readback and both inference aliases. Never
copy a rendered file over the live writer. Tests rehearse persisted activation,
restart and restoration while keeping unrelated configuration unchanged.

Revert the DNS commit and inspect OctoDNS's dry-run before merging: delete
only the newly added records. Keep existing deployment and inference records.
Issued certificates can remain; never restore the entire old ACME file over
newer unrelated renewals. Restore the old route table before rolling back
the registry: startup disables a table outside the registry.

## Isolated activation on 2026-11-03

The routes allowlist was first activated through a hand-made systemd override
of `routes.service`, without a global switch. That override matched the
generated unit from then on and was removed on 2026-11-10; routes changes now
ship with `nixos-rebuild switch` (`runbooks/june-production-capacity.md`, "No
hand-made overrides").
