# Atlas Docker: storage on the state disk

Docker's data root on atlas is `/srv/agents-state/docker` on the 1 TB state
disk (`hosts/atlas/docker.nix`). It used to be `/var/lib/docker` on the 118G
root disk, which CI and agents' test stacks filled twice on 2026-10-17. The
managed containerd keeps its snapshots under the data root, so images,
containers, volumes and build cache all move together.

Containers run in `atlas-containers.slice` (MemoryHigh 12G, MemoryMax 16G);
Hermes runs in `system-hermes.slice` (weight 1000) via `--cgroup-parent`. `atlas-docker-prune.timer`
cleans unused anonymous volumes, old unused images and build cache daily
(`hosts/atlas/docker-prune.nix`).

## Migrating /var/lib/docker (one-off)

Any change to the daemon settings restarts Docker on switch, and
`live-restore` is off, so every container stops. Do this in daylight with
Nicolai around.

What stops:

- **Hermes** (`hermes` → `hermes-image` → `docker`): down for the copy. When it
  starts again, `hermes-image` runs `git pull` in `/srv/agents-state/hermes/src`
  and rebuilds `hermes-agent:latest`, so Hermes may come back on a newer
  upstream version.
- **Agents' test stacks** (wildduck, mongo, eve sandboxes, pr* images): any
  running container is stopped and not restarted. Check `docker ps` first and
  hold off while an agent is mid-test.
- **CI runners**: unaffected, they have no Docker socket.
- **t3code**: unaffected, apart from agents whose `docker` commands fail
  during the window.

Steps, as root on atlas:

```bash
# 0. Prune first so less has to be copied (needs the prune timer deployed).
systemctl start atlas-docker-prune
docker ps                                   # note what runs; expect hermes only
df -h / /srv/agents-state

# 1. Bulk copy while Docker runs (minutes; repeated in step 3).
install -d -m 0710 /srv/agents-state/docker
rsync -aHAXS --numeric-ids --delete /var/lib/docker/ /srv/agents-state/docker/

# 2. Stop Docker. The socket must go too, or the next docker command
#    starts the daemon again on the old root.
systemctl stop atlas-docker-prune.timer hermes hermes-image docker.socket docker

# 3. Final copy (only what changed since step 1).
rsync -aHAXS --numeric-ids --delete /var/lib/docker/ /srv/agents-state/docker/

# 4. Switch to the commit that sets data-root.
nixos-rebuild switch --flake 'github:NicolaiSchmid/agent-infra/<sha>#atlas'

# 5. Start and verify.
systemctl start docker.socket docker hermes atlas-docker-prune.timer
docker info --format '{{.DockerRootDir}}'   # /srv/agents-state/docker
docker image ls | head; docker volume ls | wc -l
systemctl is-active hermes hermes-serve
cat /sys/fs/cgroup/atlas-containers.slice/memory.max 2>/dev/null   # once a test container runs
```

Keep `/var/lib/docker` until the 72h watch is over. Then free the root disk:

```bash
rm -rf /var/lib/docker
```

## Rollback

While `/var/lib/docker` still exists:

```bash
systemctl stop hermes hermes-image docker.socket docker
nixos-rebuild switch --rollback             # or switch to the previous commit
systemctl start docker.socket docker hermes
```

Docker is then back on the old root as it was at step 2. Anything created
after the migration (images, volumes) stays in `/srv/agents-state/docker` and
can be copied back with the same `rsync`, swapping source and target.

After `/var/lib/docker` is deleted, rolling back starts Docker on an empty
root: Hermes's image is rebuilt by `hermes-image`, and test stacks pull
their images again.
