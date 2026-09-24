# T3 thread dispatch and global skills

How a T3 Code thread is started without the UI, and how the `t3-thread` skill
that automates it reaches every agent session on Atlas.

## Using the skill

From any Claude Code or Codex session on Atlas (`/t3-thread`, or call the
script directly):

```bash
S=~/.claude/skills/t3-thread/t3-thread.ts

$S --list-projects
$S -p agent-infra -t "Fix the thing" -f prompt.md
$S -p fifthset --batch tasks/*.md --prelude tasks/common.md
$S -p agent-infra -t "Try it" -m "hello" --dry-run
```

It prints the thread id, branch (`t3code/<slug>`), and worktree path. Full flag
reference and the protocol gotchas are in `skills/t3-thread/SKILL.md`.

## The protocol the script wraps

Everything runs on Atlas as `nicolai`; the server is loopback-only.

1. Server origin: read `/srv/agents-state/t3code/userdata/server-runtime.json`
   (`{host, port, origin, pid, startedAt}`). Do not hardcode `127.0.0.1:3773`.
2. Project: `projection_projects` in
   `/srv/agents-state/t3code/userdata/state.sqlite`. There is no `sqlite3`
   binary; read it with `bun:sqlite` in read-only mode.
3. Token: `t3 auth session issue --ttl 10m --label <why> --json` from
   `/srv/agents-state/t3code/app/node_modules/.bin/t3`. It returns `sessionId`
   and `token`. Revoke with `t3 auth session revoke <sessionId>` when done.
4. Worktree: the HTTP bootstrap path returns 500, so create it with git:
   `git -C <workspace_root> fetch origin <default>` then
   `git worktree add -b t3code/<slug> /srv/agents-state/t3code/worktrees/<repo-basename>/t3code-<8 hex> origin/<default>`.
   `<repo-basename>` is the basename of `workspace_root`, not the project title.
5. `POST <origin>/api/orchestration/dispatch` with `Authorization: Bearer <token>`:
   first `thread.create` (threadId, projectId, title, branch, worktreePath,
   modelSelection, runtimeMode, interactionMode), then `thread.turn.start`
   (threadId, message `{messageId, role: "user", text, attachments: []}`).
   Each returns `{"sequence": N}`; the receipt for each `commandId` lands in
   `orchestration_command_receipts` with `status` and `error`.
6. Verify: `projection_threads` has the thread with a non-null `latest_turn_id`.

## Provisioning

`hosts/atlas/configuration.nix` reads every directory under `skills/` and adds a
home-manager `home.file` entry for `~/.claude/skills/<name>` and
`~/.codex/skills/<name>` (`recursive = true`, so the directory is real and only
the files are store symlinks). The flake only sees tracked files: `git add` a new
skill before `nix flake check`.

Apply to the live VM with the usual rebuild. This only re-links home files and
does not restart `t3code` or the agents:

```bash
nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra#atlas --target-host root@atlas
```

Check afterwards:

```bash
ssh atlas 'ls -la ~nicolai/.claude/skills/t3-thread ~nicolai/.codex/skills/t3-thread'
ssh atlas 'sudo -u nicolai ~nicolai/.claude/skills/t3-thread/t3-thread.ts --list-projects | head -3'
```

Until the rebuild has run, the script can be executed straight from a checkout
of this repo (`skills/t3-thread/t3-thread.ts`).
