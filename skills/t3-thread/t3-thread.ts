#!/usr/bin/env bun
// t3-thread: dispatch a new T3 Code chat thread headlessly, from any shell.
//
// Wraps the orchestration HTTP protocol (thread.create + thread.turn.start)
// so callers never reconstruct the JSON. See SKILL.md for usage and gotchas.
// Runtime: bun (sqlite, fetch, uuid). External: git and the `t3` CLI.

import { Database } from "bun:sqlite";
import { existsSync, readFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { parseArgs } from "node:util";

const T3CODE_HOME = process.env.T3CODE_HOME ?? "/srv/agents-state/t3code";
const USERDATA = join(T3CODE_HOME, "userdata");
const STATE_DB = join(USERDATA, "state.sqlite");
const RUNTIME_FILE = join(USERDATA, "server-runtime.json");
const WORKTREES = join(T3CODE_HOME, "worktrees");
const T3_CLI = join(T3CODE_HOME, "app/node_modules/.bin/t3");
const TOKEN_TTL = "10m";

const USAGE = `Usage:
  t3-thread --list-projects [--json]
  t3-thread -p <project> -t <title> (-m <text> | -f <file>) [options]
  t3-thread -p <project> --batch <prompt.md>... [--prelude <file>] [options]

Project: project id, exact project title, or workspace root path.

Options:
  -p, --project <p>         Target project (id, title, or workspace root)
  -t, --title <title>       Thread title (single dispatch)
  -m, --message <text>      First user message
  -f, --message-file <path> First user message from a file ("-" = stdin)
      --batch               Treat positional args as prompt files, one thread each.
                            Title = first "# heading" or the file name; slug = file name.
      --prelude <file>      Text prepended to every message (batch or single)
      --slug <slug>         Branch slug; branch is t3code/<slug>. Default: from title
      --base <ref>          Base ref for the worktree. Default: origin's HEAD branch
      --model <id>          Default claude-fable-5-1 (claude-* -> claudeAgent, gpt-* -> codex)
      --effort <level>      Default high
      --context-window <cw> Default 1m (claude models only)
      --runtime-mode <mode> Default full-access
      --dry-run             Resolve and print the plan; touch nothing
      --json                Machine-readable output
  -h, --help
`;

class UsageError extends Error {}

type Project = { project_id: string; title: string; workspace_root: string };
type ModelSelection = {
  instanceId: string;
  model: string;
  options: { id: string; value: string }[];
};
type Plan = {
  project: Project;
  title: string;
  message: string;
  slug: string;
  branch: string;
  baseBranch: string;
  worktreePath: string;
};
type Result = Plan & {
  threadId: string;
  createSequence: number;
  turnSequence: number;
  latestTurnId: string | null;
};

// ---------- small helpers ----------

function fail(message: string): never {
  throw new Error(message);
}

function run(cmd: string[]) {
  const proc = Bun.spawnSync(cmd, { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  return {
    ok: proc.exitCode === 0,
    stdout: proc.stdout.toString().trim(),
    stderr: proc.stderr.toString().trim(),
  };
}

function git(root: string, ...args: string[]) {
  const r = run(["git", "-C", root, ...args]);
  if (!r.ok) fail(`git ${args.join(" ")} failed in ${root}:\n${r.stderr || r.stdout}`);
  return r.stdout;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function slugify(text: string) {
  return text
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
    .replace(/-+$/, "");
}

function readText(path: string) {
  if (path === "-") return readFileSync(0, "utf8");
  if (!existsSync(path)) fail(`file not found: ${path}`);
  return readFileSync(path, "utf8");
}

// ---------- T3 state (read-only) ----------

function openState() {
  if (!existsSync(STATE_DB)) fail(`T3 state db not found at ${STATE_DB} (T3CODE_HOME=${T3CODE_HOME})`);
  return new Database(STATE_DB, { readonly: true });
}

function listProjects(db: Database): Project[] {
  return db
    .query<Project, []>(
      "select project_id, title, workspace_root from projection_projects where deleted_at is null order by title",
    )
    .all();
}

function resolveProject(db: Database, ref: string): Project {
  const projects = listProjects(db);
  const byId = projects.find((p) => p.project_id === ref);
  if (byId) return byId;
  const matches = ref.startsWith("/")
    ? projects.filter((p) => p.workspace_root === resolve(ref))
    : projects.filter((p) => p.title === ref);
  if (matches.length === 1) return matches[0];
  if (matches.length > 1) {
    const lines = matches.map((p) => `  ${p.project_id}  ${p.workspace_root}`).join("\n");
    fail(`project "${ref}" is ambiguous; pass the id:\n${lines}`);
  }
  fail(`project not found: "${ref}" (run --list-projects)`);
}

function serverOrigin(): string {
  if (!existsSync(RUNTIME_FILE)) fail(`T3 server is not running: ${RUNTIME_FILE} missing`);
  const rt = JSON.parse(readFileSync(RUNTIME_FILE, "utf8")) as { origin: string; pid: number };
  try {
    process.kill(rt.pid, 0);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ESRCH") {
      fail(`T3 server is not running: pid ${rt.pid} from ${RUNTIME_FILE} is dead (systemctl status t3code)`);
    }
  }
  return rt.origin;
}

// ---------- auth ----------

function issueToken(label: string) {
  if (!existsSync(T3_CLI)) fail(`t3 CLI not found at ${T3_CLI}`);
  const r = run([T3_CLI, "auth", "session", "issue", "--base-dir", T3CODE_HOME, "--ttl", TOKEN_TTL, "--label", label, "--json"]);
  if (!r.ok) fail(`t3 auth session issue failed:\n${r.stderr || r.stdout}`);
  const { sessionId, token } = JSON.parse(r.stdout) as { sessionId: string; token: string };
  return { sessionId, token };
}

function revokeToken(sessionId: string) {
  const r = run([T3_CLI, "auth", "session", "revoke", "--base-dir", T3CODE_HOME, sessionId]);
  if (!r.ok) console.error(`warning: failed to revoke session ${sessionId}: ${r.stderr || r.stdout}`);
}

// ---------- git worktree ----------

function defaultBranch(root: string): string {
  const sym = run(["git", "-C", root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"]);
  if (sym.ok && sym.stdout.startsWith("origin/")) return sym.stdout.slice("origin/".length);
  const show = run(["git", "-C", root, "remote", "show", "origin"]);
  const m = show.stdout.match(/HEAD branch: (\S+)/);
  if (m && m[1] !== "(unknown)") return m[1];
  fail(`cannot determine origin's default branch in ${root}; pass --base <branch>`);
}

function freshWorktreePath(root: string): string {
  const dir = join(WORKTREES, basename(root));
  for (let i = 0; i < 8; i++) {
    const hex = Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => b.toString(16).padStart(2, "0")).join("");
    const path = join(dir, `t3code-${hex}`);
    if (!existsSync(path)) return path;
  }
  fail(`could not find a free worktree path under ${dir}`);
}

function assertBranchFree(root: string, branch: string) {
  if (run(["git", "-C", root, "show-ref", "--verify", "--quiet", `refs/heads/${branch}`]).ok) {
    fail(`branch ${branch} already exists in ${root}; pass --slug <other>`);
  }
}

function createWorktree(plan: Plan) {
  const root = plan.project.workspace_root;
  git(root, "fetch", "origin", plan.baseBranch);
  git(root, "worktree", "add", "-q", "-b", plan.branch, plan.worktreePath, `origin/${plan.baseBranch}`);
}

function removeWorktree(plan: Plan) {
  const root = plan.project.workspace_root;
  run(["git", "-C", root, "worktree", "remove", "--force", plan.worktreePath]);
  run(["git", "-C", root, "branch", "-D", plan.branch]);
}

// ---------- orchestration protocol ----------

function buildModelSelection(model: string, effort: string, contextWindow: string): ModelSelection {
  if (model.startsWith("gpt")) {
    return { instanceId: "codex", model, options: [{ id: "reasoningEffort", value: effort }] };
  }
  return {
    instanceId: "claudeAgent",
    model,
    options: [
      { id: "effort", value: effort },
      { id: "contextWindow", value: contextWindow },
    ],
  };
}

type Dispatcher = (command: Record<string, unknown>) => Promise<number>;

function makeDispatcher(origin: string, token: string, db: Database): Dispatcher {
  const receipt = db.query<{ status: string; error: string | null }, [string]>(
    "select status, error from orchestration_command_receipts where command_id = ?",
  );
  return async (command) => {
    const commandId = crypto.randomUUID();
    const body = JSON.stringify({ ...command, commandId, createdAt: new Date().toISOString() });
    let res: Response;
    try {
      res = await fetch(`${origin}/api/orchestration/dispatch`, {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body,
      });
    } catch (e) {
      fail(`T3 server unreachable at ${origin}: ${(e as Error).message}`);
    }
    const text = await res.text();
    const detail = text || res.statusText || "(empty response body)";
    if (res.status === 401 || res.status === 403) fail(`T3 refused the bearer token (${res.status}): ${detail}`);
    if (!res.ok) fail(`${command.type} dispatch failed (${res.status}): ${detail}`);
    const sequence = (JSON.parse(text) as { sequence?: number }).sequence;
    if (typeof sequence !== "number") fail(`${command.type} dispatch returned no sequence: ${text}`);
    // The receipt row is written once the command is applied; rejections land there.
    for (let i = 0; i < 20; i++) {
      const row = receipt.get(commandId);
      if (row?.status === "rejected") fail(`${command.type} was rejected by T3: ${row.error}`);
      if (row) break;
      await sleep(150);
    }
    return sequence;
  };
}

async function dispatchThread(
  plan: Plan,
  dispatch: Dispatcher,
  db: Database,
  modelSelection: ModelSelection,
  runtimeMode: string,
): Promise<Result> {
  const threadId = crypto.randomUUID();
  const common = { modelSelection, runtimeMode, interactionMode: "default" };

  createWorktree(plan);
  let createSequence: number;
  try {
    createSequence = await dispatch({
      type: "thread.create",
      threadId,
      projectId: plan.project.project_id,
      title: plan.title,
      branch: plan.branch,
      worktreePath: plan.worktreePath,
      ...common,
    });
  } catch (e) {
    removeWorktree(plan);
    throw e;
  }

  const turnSequence = await dispatch({
    type: "thread.turn.start",
    threadId,
    message: { messageId: crypto.randomUUID(), role: "user", text: plan.message, attachments: [] },
    ...common,
  });

  const turnQuery = db.query<{ latest_turn_id: string | null }, [string]>(
    "select latest_turn_id from projection_threads where thread_id = ?",
  );
  let latestTurnId: string | null = null;
  for (let i = 0; i < 40 && !latestTurnId; i++) {
    latestTurnId = turnQuery.get(threadId)?.latest_turn_id ?? null;
    if (!latestTurnId) await sleep(250);
  }
  if (!latestTurnId) {
    console.error(`warning: thread ${threadId} exists but no turn started within 10s; check T3.`);
  }
  return { ...plan, threadId, createSequence, turnSequence, latestTurnId };
}

// ---------- main ----------

function parse(argv: string[]) {
  const { values, positionals } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      "list-projects": { type: "boolean" },
      project: { type: "string", short: "p" },
      title: { type: "string", short: "t" },
      message: { type: "string", short: "m" },
      "message-file": { type: "string", short: "f" },
      batch: { type: "boolean" },
      prelude: { type: "string" },
      slug: { type: "string" },
      base: { type: "string" },
      model: { type: "string", default: "claude-fable-5-1" },
      effort: { type: "string", default: "high" },
      "context-window": { type: "string", default: "1m" },
      "runtime-mode": { type: "string", default: "full-access" },
      "dry-run": { type: "boolean" },
      json: { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
  });
  return { values, positionals };
}

function buildPlans(db: Database, values: ReturnType<typeof parse>["values"], positionals: string[]): Plan[] {
  if (!values.project) throw new UsageError("--project is required");
  const project = resolveProject(db, values.project);
  if (!existsSync(join(project.workspace_root, ".git"))) {
    fail(`workspace root ${project.workspace_root} is not a git checkout`);
  }
  const baseBranch = values.base ?? defaultBranch(project.workspace_root);
  const prelude = values.prelude ? readText(values.prelude) : "";

  const specs: { title: string; slug: string; message: string }[] = [];
  if (values.batch) {
    if (positionals.length === 0) throw new UsageError("--batch needs at least one prompt file");
    for (const file of positionals) {
      const text = readText(file);
      const heading = text.match(/^#\s+(.+)$/m)?.[1]?.trim();
      const stem = basename(file).replace(/\.[^.]+$/, "");
      specs.push({ title: heading ?? stem, slug: slugify(stem), message: prelude + text });
    }
  } else {
    if (!values.title) throw new UsageError("--title is required");
    if (positionals.length > 0) throw new UsageError(`unexpected arguments: ${positionals.join(" ")}`);
    const text = values.message ?? (values["message-file"] ? readText(values["message-file"]) : undefined);
    if (text === undefined) throw new UsageError("one of --message or --message-file is required");
    specs.push({ title: values.title, slug: values.slug ?? slugify(values.title), message: prelude + text });
  }

  const plans: Plan[] = [];
  for (const spec of specs) {
    if (!spec.slug) fail(`cannot derive a branch slug from "${spec.title}"; pass --slug`);
    if (!spec.message.trim()) fail(`message for "${spec.title}" is empty`);
    const branch = `t3code/${spec.slug}`;
    if (plans.some((p) => p.branch === branch)) fail(`duplicate branch ${branch} in batch`);
    assertBranchFree(project.workspace_root, branch);
    plans.push({
      project,
      title: spec.title,
      message: spec.message,
      slug: spec.slug,
      branch,
      baseBranch,
      worktreePath: freshWorktreePath(project.workspace_root),
    });
  }
  return plans;
}

function printPlan(p: Plan) {
  console.log(`would dispatch ${p.title}`);
  console.log(`  project:  ${p.project.title} (${p.project.project_id})`);
  console.log(`  branch:   ${p.branch} (from origin/${p.baseBranch})`);
  console.log(`  worktree: ${p.worktreePath}`);
}

function printResult(r: Result) {
  console.log(`dispatched ${r.title}`);
  console.log(`  thread:   ${r.threadId}${r.latestTurnId ? "" : " (turn not yet visible)"}`);
  console.log(`  branch:   ${r.branch}`);
  console.log(`  worktree: ${r.worktreePath}`);
}

async function main() {
  const { values, positionals } = parse(process.argv.slice(2));
  if (values.help) {
    console.log(USAGE);
    return;
  }

  const db = openState();
  if (values["list-projects"]) {
    const projects = listProjects(db);
    if (values.json) console.log(JSON.stringify(projects, null, 2));
    else for (const p of projects) console.log(`${p.project_id}  ${p.title.padEnd(28)} ${p.workspace_root}`);
    return;
  }

  const plans = buildPlans(db, values, positionals);
  const modelSelection = buildModelSelection(values.model!, values.effort!, values["context-window"]!);

  if (values["dry-run"]) {
    if (values.json) {
      console.log(JSON.stringify({ plans, modelSelection, runtimeMode: values["runtime-mode"] }, null, 2));
    } else {
      for (const p of plans) printPlan(p);
      console.log(`  model:    ${JSON.stringify(modelSelection)}`);
    }
    return;
  }

  const origin = serverOrigin();
  const { sessionId, token } = issueToken(`t3-thread ${new Date().toISOString()}`);
  const results: Result[] = [];
  const failures: { plan: Plan; error: string }[] = [];
  try {
    const dispatch = makeDispatcher(origin, token, db);
    for (const plan of plans) {
      try {
        const r = await dispatchThread(plan, dispatch, db, modelSelection, values["runtime-mode"]!);
        results.push(r);
        if (!values.json) printResult(r);
      } catch (e) {
        failures.push({ plan, error: (e as Error).message });
        if (!values.json) console.error(`failed ${plan.title}: ${(e as Error).message}`);
      }
    }
  } finally {
    revokeToken(sessionId);
  }

  if (values.json) {
    const strip = ({ message: _m, ...rest }: Result) => rest;
    console.log(JSON.stringify({ threads: results.map(strip), failures }, null, 2));
  }
  if (failures.length > 0) process.exit(1);
}

main().catch((e) => {
  if (e instanceof UsageError) {
    console.error(`error: ${e.message}\n\n${USAGE}`);
    process.exit(2);
  }
  console.error(`error: ${(e as Error).message}`);
  process.exit(1);
});
