# June production capacity

June production has its own bounded `juneprod.slice`, outside the shared
`client-data.slice` (`hosts/black/client-data.nix`): a container limit alone
cannot exceed that slice's ceiling. The full production bundle and a
post-write stopped-checkpoint recovery passed in an isolated same-image trial
on 2026-11-03.

Every June production setting is in its entry in
`hosts/black/convex/deployments.nix`: memory, CPUs, PIDs, slice, image and
the timeouts it adds to the template. `hosts/black/convex.nix` derives the
slice and the backend's Compose overlay from that entry; other deployments
take the same path with their own entries.

## Changing it

1. Change the entry by pull request. Recheck host memory first: atlas's boot
   memory (`hosts/black/libvirt.nix`) plus every slice ceiling must leave at
   least 4 GiB for black.
2. After merge, on black:

   ```sh
   nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra/<merge-commit>#black
   ```

   Any change to the entry recreates June's backend (a few seconds without
   the API and WebSocket). Coordinate with June: no backend deploy, long
   action or token refresh in flight.
3. Verify the running container against the entry: `docker inspect
   convex-june-prod-backend-1` (image, `Env`, `HostConfig.Memory`,
   `CgroupParent`), `systemctl show juneprod.slice -p MemoryMax -p
   CPUQuotaPerSecUSec`, health, and `https://june.convex.modusservice.com/version`.

Rollback is a revert and another switch. Data stays in
`/var/lib/client-data/convex/june-prod` either way; never restore an older
SQLite backup over a live deployment.

## No hand-made overrides

Do not change June's unit with `systemctl edit`, `set-property`, `mask` or a
file under `/etc/systemd/system.control/`. Such an override outranks the
generated unit, so the next switch changes the unit and systemd still runs the
old command: from 2026-11-04 to 2026-11-10 June production ran a pinned
command that ignored two deploys and would have reverted it to 4 GiB on its
next restart. Activation now deletes every override of the client-data units
(`convex-units-nix-only` in `hosts/black/convex.nix`). A live change that
cannot wait for a merge (`docker update`, `systemctl set-property --runtime`)
lasts until the next switch; land the same change in Nix right after.
