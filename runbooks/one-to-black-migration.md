# one/domovoi -> black/atlas migration

This runbook migrates the old agent VM state from `one`/`domovoi` to
`black`/`atlas`.

Do not run the cutover section until Nicolai explicitly approves downtime for
the old `t3code`/Hermes environment.

## Current shape

- Old service VM: `domovoi`, reached through Tailscale/SSH.
- New service VM: `atlas`, running inside libvirt on `black`.
- New staging Tailnet names:
  - `atlas.takaya-buri.ts.net`
  - `atlas-t3code.takaya-buri.ts.net`
- Future production Tailnet names after cutover:
  - `atlas` can keep its name for SSH/admin.
  - `atlas-t3code` should be renamed/swapped to `t3code` only when the old
    `t3code` node is retired.

## What must migrate

Primary state:

- `/srv/agents-state/`

Important contents verified under that tree:

- `/srv/agents-state/nicolai/.codex/`
- `/srv/agents-state/nicolai/.claude/`
- `/srv/agents-state/nicolai/.config/gh/`
- `/srv/agents-state/hermes/data/`
- `/srv/agents-state/secrets/`
- `/srv/agents-state/tailscale/`
- `/srv/agents-state/t3code/`
- `/srv/agents-state/workspace/`

Small root-level auth/config files outside the persisted state mount:

- `/root/.claude/.credentials.json`
- `/root/.claude.json`
- `/root/.config/gh/config.yml`
- `/root/.config/gh/hosts.yml`
- `/root/.ssh/id_ed25519`
- `/root/.ssh/id_ed25519.pub`
- `/root/.ssh/known_hosts`

Do not migrate as durable state:

- `/tmp/` caches/worktrees
- `/nix/`
- `/var/lib/docker` image layers/build cache
- `/var/lib/systemd/coredump`

Old Docker note:

- The running old Hermes container only uses bind mounts:
  - `/srv/agents-state/hermes/data -> /opt/data`
  - `/srv/agents-state/secrets/hermes_ssh -> /secrets/hermes_ssh`
- Two anonymous Docker volumes exist on old `domovoi`, but they are dangling.
  Archive them before destroying the old VM if we want a forensic fallback; do
  not treat them as live Hermes state unless a later check shows they are
  mounted.

## Preflight

Run from the Mac:

```bash
ssh domovoi 'hostname; df -hT / /srv/agents-state; systemctl is-active t3code hermes'
ssh -i ~/.ssh/agent/black_admin \
  -o ProxyCommand="ssh -i ~/.ssh/agent/black_admin -W %h:%p root@65.109.71.108" \
  root@192.168.122.226 \
  'hostname; df -hT / /srv/agents-state; systemctl is-active t3code hermes'
```

Check that old state is actively changing:

```bash
ssh domovoi 'ps -eo pid,etime,comm,args | rg "t3code|hermes|codex|claude|update_workspace" || true'
```

## Warm copy

This can run while old `domovoi` stays online. It intentionally excludes
runtime Tailscale node state so the staging `atlas` Tailnet identities are not
overwritten before cutover.

```bash
rsync -aHAX --numeric-ids --info=progress2 \
  --exclude '/tailscale/***' \
  --exclude '/ts-t3code/***' \
  domovoi:/srv/agents-state/ \
  root@atlas.takaya-buri.ts.net:/srv/agents-state/
```

Copy root-level auth/config crumbs into a quarantine directory rather than
overwriting the new VM root immediately:

```bash
ssh root@atlas.takaya-buri.ts.net 'mkdir -p /srv/agents-state/migration/root-domovoi'

ssh domovoi 'sudo tar -C /root -cf - \
  .claude/.credentials.json \
  .claude.json \
  .config/gh/config.yml \
  .config/gh/hosts.yml \
  .ssh/id_ed25519 \
  .ssh/id_ed25519.pub \
  .ssh/known_hosts' |
ssh root@atlas.takaya-buri.ts.net \
  'tar -C /srv/agents-state/migration/root-domovoi -xpf -'
```

Optional forensic archive for dangling old Docker volumes:

```bash
ssh domovoi 'sudo tar -C /var/lib/docker/volumes -cf - \
  709ad31300ca3e81885066f5f25ab5e938059892051f1c575f3449dbce09fa8e \
  f13119ed882eb4c9f70e07e2c293135efb6b2ef68aab8b482b662d95a255e2d0' |
ssh root@atlas.takaya-buri.ts.net \
  'mkdir -p /srv/agents-state/migration && cat > /srv/agents-state/migration/domovoi-dangling-docker-volumes.tar'
```

## Cutover window

Only run after explicit approval.

1. Stop old writers on `domovoi`.

```bash
ssh domovoi 'sudo systemctl stop t3code hermes hermes-serve tailscale-t3code-serve tailscaled-t3code || true'
```

2. Final sync.

```bash
rsync -aHAX --numeric-ids --delete --info=progress2 \
  --exclude '/tailscale/***' \
  --exclude '/ts-t3code/***' \
  domovoi:/srv/agents-state/ \
  root@atlas.takaya-buri.ts.net:/srv/agents-state/
```

3. Fix ownership and restart new services on `atlas`.

```bash
ssh root@atlas.takaya-buri.ts.net '
  chown -R nicolai:users /srv/agents-state/nicolai /srv/agents-state/t3code /srv/agents-state/workspace
  chown -R root:root /srv/agents-state/secrets /srv/agents-state/hermes
  chmod 700 /srv/agents-state/secrets
  systemctl restart t3code hermes hermes-serve
'
```

4. Validate new services before renaming Tailnet nodes.

```bash
curl -fsS https://atlas-t3code.takaya-buri.ts.net/.well-known/t3/environment | jq .
ssh root@atlas.takaya-buri.ts.net 'systemctl --failed --no-pager; systemctl is-active t3code hermes hermes-serve'
```

5. Tailnet/DNS swap.

- In the Tailscale admin UI, remove or rename the old `t3code` device.
- Rename `atlas-t3code` to `t3code`.
- Verify:

```bash
curl -fsS https://t3code.takaya-buri.ts.net/.well-known/t3/environment | jq .
```

6. Keep old `domovoi` powered off but available until the new environment has
   been used successfully.

## Rollback

If validation fails before Tailnet rename, restart old services:

```bash
ssh domovoi 'sudo systemctl start tailscaled-t3code tailscale-t3code-serve t3code hermes hermes-serve || true'
```

If validation fails after Tailnet rename, rename the devices back in Tailscale
admin and restart old services.
