# June production capacity

June production has its own bounded `juneprod.slice`. The full production
bundle and a post-write stopped-checkpoint recovery passed in an isolated
same-image trial on 2026-11-03. Resource values live in
`hosts/black/convex/june-prod-capacity.nix`; the slice and production-only
Compose overlay derive from them. Other containers retain the shared demo
slice. A container limit alone cannot supply this capacity under that slice's
smaller shared memory ceiling.

Before a scoped activation, coordinate one backend restart with the routing
operator. Verify the target is still empty using authenticated component,
schema, function and storage queries. Privately retain an online SQLite
backup, empty storage inventory, compose/env/secrets, unit and existing
slice/drop-in state. Keep the backup outside the data directory. Recheck
available host memory after allowing the entire new target allocation; retain
at least 4 GiB for the host. Inspect every cgroup ancestor, including CPU,
memory, swap and PID limits.

Build only the `convex-june-prod.service` and `juneprod.slice` unit
attributes, retain their closures, and install the slice plus a persistent
production-service drop-in using those immutable paths. For this scoped
activation, append the generated capacity overlay to the captured live Compose
command and environment file. Current main also changes the bridge name; do
not activate that template change here. Compare both resolved configurations
and accept only resource fields. Preserve any unrelated
service override, especially `routes.service`. Recreate only the production
backend with that resource-only Compose command. Do not switch the global NixOS
system, change the Docker daemon's default parent, or modify phone services.
The checked-in Nix definition owns the configuration for the next normal
system deployment; the scoped override persists across reboots until that
handover.

After recreation verify image, environment, data mount, networking, port
bindings and Traefik labels against the private before-state. Confirm effective
ancestor limits, health and the authenticated empty/inert state, then release
routing probes. An empty-target rollback restores the saved service override,
original Compose command and prior slice placement. Stop and investigate if
any application data or code appears: never downgrade limits or restore the
empty SQLite backup after migration.

This resource change deploys no June code, imports no data and changes no
client endpoint. The trial proves recovery into a new directory using the same
backend image; cloud reverse import and external-effect reconciliation remain
separate migration gates.
