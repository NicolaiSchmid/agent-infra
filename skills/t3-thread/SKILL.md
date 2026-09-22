---
name: t3-thread
description: Launch, dispatch, or spawn a NEW T3 Code chat thread in a given project from inside any Claude Code or Codex session — "open a new thread in project X", "dispatch this prompt as a T3 thread", "spawn N threads from these prompt files", "which T3 projects exist". Creates the git worktree, issues and revokes a scoped bearer token, sends thread.create + thread.turn.start over the local orchestration API, and returns the thread id, branch, and worktree path. Use it instead of reconstructing the T3 HTTP protocol by hand.
---

# t3-thread — dispatch a T3 Code thread headlessly

The script beside this file does the whole protocol. Call it; do not rebuild the JSON.

```bash
S=~/.claude/skills/t3-thread/t3-thread.ts        # same file under ~/.codex/skills/t3-thread/

$S --list-projects [--json]                        # project id, title, workspace root
$S -p <project> -t "<title>" -m "<first message>"  # one thread
$S -p <project> -t "<title>" -f prompt.md          # message from a file ("-" = stdin)
$S -p <project> --batch a.md b.md c.md --prelude common.md   # N threads from N files
$S ... --dry-run                                   # resolve everything, touch nothing
```

`<project>` is a project id, an exact project title, or a workspace root path.
Ambiguous titles (several projects share one) fail with the candidate ids listed.

Output per thread (or `--json`):

```
dispatched <title>
  thread:   <uuid>
  branch:   t3code/<slug>
  worktree: /srv/agents-state/t3code/worktrees/<repo-basename>/t3code-<8 hex>
```

## Defaults and knobs

| flag | default | notes |
|---|---|---|
| `--model` | `claude-fable-5-1` | `claude-*` maps to `instanceId: claudeAgent`, `gpt-*` to `codex` |
| `--effort` | `high` | sent as `effort` (claude) or `reasoningEffort` (codex) |
| `--context-window` | `1m` | claude models only |
| `--runtime-mode` | `full-access` | |
| `--slug` | slugified title | branch is always `t3code/<slug>`; fails if the branch exists |
| `--base` | origin's HEAD branch | worktree starts at `origin/<base>` after a fetch |

Batch mode: title = first `# heading` in the file, else the file stem; slug = file stem.
`--prelude` prepends a shared file to every message (house rules, repo recipe, etc.).

## Writing the first message

The thread has no other context. Put in the message what a fresh agent needs: repo, branch
convention, what to build, how to verify, how to hand over. Batch dispatches usually want a
`common.md` prelude with the repo's working rules plus one file per task.

## What the script does, in order

1. Reads `server-runtime.json` for the server origin and checks the pid is alive.
2. Resolves the project in `projection_projects` (read-only sqlite via bun).
3. Issues a bearer token with `t3 auth session issue --ttl 10m --json`; revokes it in a
   `finally` block, on success and on failure.
4. `git fetch origin <base>` and `git worktree add -b t3code/<slug> <path> origin/<base>`.
5. `POST /api/orchestration/dispatch` with `thread.create`, then `thread.turn.start`.
   Each command's receipt is read back from `orchestration_command_receipts`; a rejected
   `thread.create` rolls the worktree and branch back and prints the receipt's error.
6. Waits up to 10 s for `projection_threads.latest_turn_id` to be set, then prints the result.

Exit codes: 0 ok, 1 dispatch or environment error, 2 usage error.

## Gotchas (learned the hard way; do not rediscover)

- **HTTP does not bootstrap worktrees.** `bootstrap.createThread` / `prepareWorktree` over HTTP
  return 500 `orchestration_dispatch_failed`. The worktree must exist before `thread.create`,
  which is why the script creates it with plain git.
- **Worktree path rule.** T3 keeps worktrees at
  `/srv/agents-state/t3code/worktrees/<repo-basename>/t3code-<8 hex>` where `<repo-basename>`
  is the basename of the project's `workspace_root`, not its title. fifthset's root is
  `.../personal/tipper`, so its worktrees live under `worktrees/tipper/`.
- **No `sqlite3` binary on the box.** Read `state.sqlite` with `bun:sqlite`
  (`new Database(path, {readonly: true})`). Tables: `projection_projects`,
  `projection_threads` (`thread_id, project_id, title, branch, worktree_path, latest_turn_id`),
  `orchestration_command_receipts` (`command_id, status, error`).
- **Token revocation.** `t3 auth session issue --json` returns `sessionId`; revoke with it.
  If you must find a session in `t3 auth session list --json`, the label sits at
  `.client.label` and can be null; filter with `(.client.label // .label // "")`.
- **Default branch.** Not every repo uses `main`; the script asks git for origin's HEAD
  branch and accepts `--base` to override.
- **Do not hardcode host/port.** `server-runtime.json` (`{host, port, origin, pid, startedAt}`)
  is the source of truth; the server is loopback-only on the box.
- **Bad token** is a 401 with `{"code":"auth_invalid"}`; the script reports it as such.

## Environment

`T3CODE_HOME` (default `/srv/agents-state/t3code`) locates `userdata/`, `worktrees/`, and the
`t3` CLI at `app/node_modules/.bin/t3`. Needs `bun` and `git` on PATH. Provisioned by
agent-infra (`hosts/atlas/configuration.nix`), see that repo's `runbooks/t3-thread.md`.
