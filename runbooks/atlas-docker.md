# Atlas Docker: storage on the state disk

Docker's data root on atlas is `/srv/agents-state/docker` on the 1 TB state
disk (`hosts/atlas/docker.nix`). It used to be `/var/lib/docker` on the 118G
root disk, which CI and agents' test stacks filled twice on 2026-10-17. The
managed containerd keeps its snapshots under the data root, so images,
containers, volumes and build cache all move together. No Docker metadata
stores the data root's path, so a copy works as is.

Containers run in `atlas.slice/atlas-containers.slice` (MemoryHigh 12G,
MemoryMax 16G, inside the 28G shared with CI). The Hermes container runs in
`system.slice/system-hermes.slice` (weight 1000) via `--cgroup-parent`.
`atlas-docker-prune.timer` cleans unused anonymous volumes, unused images
pulled more than 24h ago and old build cache daily
(`hosts/atlas/docker-prune.nix`). Weights and limits for the whole host:
`runbooks/atlas-build-sweep.md`.

## Migrating /var/lib/docker (one-off)

**Do not merge the PR that sets `data-root` before this window.** Any switch
that includes it restarts Docker on an empty `/srv/agents-state/docker`:
Hermes would rebuild and volumes would look lost. Deploy step 4 by the PR's
commit, then merge.

A change to the daemon settings restarts Docker on switch, and `live-restore`
is off, so every container stops. Do this in daylight with Nicolai around.

What stops:

- **Hermes** (`hermes` → `hermes-image` → `docker`): down from step 2 until the
  switch. When it starts again, `hermes-image` runs `git pull` in
  `/srv/agents-state/hermes/src` and rebuilds `hermes-agent:latest`, so Hermes
  may come back on a newer upstream version, and after a prune the rebuild
  starts from scratch (several minutes).
- **Agents' test stacks** (wildduck, mongo, eve sandboxes, pr* images): any
  running container is stopped and not restarted. Check `docker ps` first and
  hold off while an agent is mid-test.
- **CI runners**: unaffected, they have no Docker socket.
- **t3code**: unaffected, apart from agents whose `docker` commands fail
  during the window.

Steps, as root on atlas (`sudo -i`):

```bash
# 0. Look at what runs, and drop unused anonymous volumes so less is copied.
#    Keep images and build cache: Hermes's base images and build cache make
#    the hermes-image rebuild in step 4 take seconds instead of minutes.
docker ps --format '{{.Names}}\t{{.Status}}'   # expect hermes only; any other
                                                # container is an agent's test
                                                # stack: wait for it to finish
pgrep -af 'docker(-compose)? (compose )?(run|up|build|start|exec)' | grep -v 'name hermes'
docker volume prune --force
du -sh /var/lib/docker; docker system df
df -h / /srv/agents-state

# 1. Bulk copy while Docker runs (minutes; step 3 repeats it). -x keeps rsync
#    out of the running containers' mounts.
install -d -m 0710 /srv/agents-state/docker
rsync -aHAXSx --numeric-ids --delete /var/lib/docker/ /srv/agents-state/docker/

# 2. Stop Docker. The socket must go too, or the next docker command starts
#    the daemon again on the old root. Then make sure nothing is left that
#    could still write (docker.service uses KillMode=process).
systemctl stop atlas-docker-prune.timer hermes hermes-image docker.socket docker
findmnt -R /var/lib/docker                  # must print nothing
pgrep -af 'containerd --config /var/run/docker|containerd-shim' || echo "none left"

# 3. Final copy (only what changed since step 1).
rsync -aHAXSx --numeric-ids --delete /var/lib/docker/ /srv/agents-state/docker/

# 4. Switch to the PR's head commit. The switch starts docker.socket, docker,
#    hermes (hermes-image rebuilds first, which can take minutes) and the
#    prune timer by itself, on the new root.
sha=$(gh pr view 25 --repo NicolaiSchmid/agent-infra --json headRefOid -q .headRefOid)
nixos-rebuild switch --flake "github:NicolaiSchmid/agent-infra/$sha#atlas"

# 5. Verify.
systemctl is-active docker hermes hermes-serve atlas-docker-prune.timer
docker info --format '{{.DockerRootDir}} {{.CgroupDriver}}'   # /srv/agents-state/docker systemd
docker image ls | head; docker volume ls | wc -l              # same as in step 0
grep . /proc/$(docker inspect -f '{{.State.Pid}}' hermes)/cgroup   # .../system.slice/system-hermes.slice/docker-<id>.scope
docker run --rm alpine:3.22 cat /proc/self/cgroup             # .../atlas.slice/atlas-containers.slice/docker-<id>.scope
df -h / /srv/agents-state
```

Then merge the PR (merge commit) so `main` matches what atlas runs.

## Watch (72h after the switch)

Every 6h: `df -h /` (should no longer grow with Docker), `du -sh
/srv/agents-state/docker`, `journalctl -u docker -p warning --since -6h`,
`systemctl is-active hermes`, `journalctl -u atlas-docker-prune -n 20`.

When the 72h are over and nothing went wrong, free the root disk:

```bash
rm -rf /var/lib/docker
```

## Rollback

While `/var/lib/docker` still exists:

```bash
systemctl stop atlas-docker-prune.timer hermes hermes-image docker.socket docker
nixos-rebuild switch --rollback             # or switch to the previous commit
systemctl is-active docker hermes           # the switch starts them again
```

Docker is then back on the old root as it was at step 2, and Hermes back in
`system.slice` without `--cgroup-parent`. Anything created after the
migration (images, volumes) stays in `/srv/agents-state/docker` and can be
copied back with the same `rsync`, swapping source and target.

After `/var/lib/docker` is deleted, rolling back starts Docker on an empty
root: Hermes's image is rebuilt by `hermes-image`, and test stacks pull
their images again.
