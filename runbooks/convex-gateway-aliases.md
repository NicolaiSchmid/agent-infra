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

1. Merge the infra PR after checking its exact head. Use the isolated route
   service activation below; current main includes undeployed phone work.
   Confirm routes health and unchanged inference. The allowlist alone creates
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

Black runs `/nix/store/474sa8dmrkdsj4mrs0aynsjsy6zpv6x2-nixos-system-black-26.05.20260707.0ad6f47`.
Evaluating the pinned source `dadec0dccd4fb3245f1dfe16d7d84d1456d132dd`
produces its exact derivation `3m6b9syxbygqd3jwp34zviwrb36dbakv`.
The deployment branch `deploy/black-routing-only-936258ad`, commit
`ce6725d69d4fcc66fbb24d7aaf1d2e3680162d9a`, applies only the reviewed
routing file delta to that source. Its diff contains four files under
`hosts/black/routes*`; no phone, firewall, host, package or lockfile changes.
All six route tests pass locally and in the Nix build. Codex CLI review
found no actionable routing defects.

Build this immutable artifact on black:

```sh
nix build github:NicolaiSchmid/agent-infra/ce6725d69d4fcc66fbb24d7aaf1d2e3680162d9a#nixosConfigurations.black.config.system.build.toplevel \
  --out-link /var/lib/client-data/backups/convex-routing-936258ad/routing-only-ce6725d
```

The result is `/nix/store/8fdcb115q3sx69rfzc1mh4plisgnh58d-nixos-system-black-26.05.20260707.0ad6f47`.
Its global dry activation still schedules dbus reload and polkit restart,
although both unit files are byte-identical to the baseline. Do not switch.
`python3 scripts/activate-routing-only.py dry-run` validates the baseline and limits
the change to the route unit's command fields. After private backups,
`apply` installs a persistent systemd control drop-in derived from that
exact built unit and reloads only routes. It automatically removes the
drop-in and reloads baseline routes if reload or health verification fails.
Run `rollback` to rehearse restoration before applying again.

The drop-in is `/etc/systemd/system.control/routes.service.d/90-routing-only-936258ad.conf`.
The system profile remains at its baseline; keep the build's GC root above.
This is an explicit service-only deployment, not a global Nix rollout.
Before a future global rollout, reconcile and remove this override so it
cannot mask a later routes unit. Map rollback must precede service rollback
once aliases have been published.

Black has Python at `/nix/store/l9k0anq0z7zz81zcwy035jfwap9ga6rl-python3-3.13.13/bin/python3`; use that interpreter when `python3` is absent from PATH.
