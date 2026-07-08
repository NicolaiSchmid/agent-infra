#!/usr/bin/env node
// Drop-in gh wrapper for t3code's PR status sweep.
//
// t3 issues many concurrent `gh pr list --head <branch> --json <fields>` calls.
// The real gh implementation burns GitHub GraphQL quota for each call. This
// shim intercepts only that exact shape, refreshes one per-repo REST cache with
// conditional requests, and serves all branch lookups from the cache. Every
// other command falls through to the real gh.
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const REAL_GH = process.env.GH_PR_SHIM_REAL_GH || "/run/current-system/sw/bin/gh";
const CACHE_DIR = join(process.env.HOME || "/tmp", ".cache", "gh-pr-shim");
const TTL_MS = 20_000;
const KNOWN_FIELDS = new Set([
  "number",
  "title",
  "url",
  "baseRefName",
  "headRefName",
  "state",
  "mergedAt",
  "updatedAt",
  "isCrossRepository",
  "headRepository",
  "headRepositoryOwner",
]);

const stripAnsi = (s) => (s || "").replace(/\x1b\[[0-9;]*m/g, "");

function dbg(msg) {
  if (!process.env.GH_PR_SHIM_DEBUG) return;
  try {
    mkdirSync(CACHE_DIR, { recursive: true });
    writeFileSync(join(CACHE_DIR, "debug.log"), `${new Date().toISOString()} pid=${process.pid} :: ${msg}\n`, {
      flag: "a",
    });
  } catch {}
}

function passthrough() {
  dbg(`PASSTHROUGH argv=${JSON.stringify(args)}`);
  const result = spawnSync(REAL_GH, args, { stdio: "inherit" });
  process.exit(result.status ?? 1);
}

function parseT3Call() {
  if (args[0] !== "pr" || args[1] !== "list") return null;
  const rest = args.slice(2);
  let head = null;
  let json = null;
  let state = "open";

  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === "--head") head = rest[++i];
    else if (rest[i] === "--json") json = rest[++i];
    else if (rest[i] === "--state") state = rest[++i];
    else if (rest[i] === "-R" || rest[i] === "--repo") return null;
  }

  if (!head || !json) return null;
  if (json.split(",").some((field) => !KNOWN_FIELDS.has(field))) return null;
  return { head, state };
}

function stateMatches(prState, want) {
  if (want === "all") return true;
  if (want === "open") return prState === "OPEN";
  if (want === "merged") return prState === "MERGED";
  if (want === "closed") return prState === "CLOSED" || prState === "MERGED";
  return true;
}

const t3 = parseT3Call();
if (!t3) passthrough();

function mapPR(pr) {
  const headRepo = pr.head?.repo || null;
  return {
    number: pr.number,
    title: pr.title,
    url: pr.html_url,
    baseRefName: pr.base?.ref ?? null,
    headRefName: pr.head?.ref ?? null,
    state: pr.merged_at ? "MERGED" : String(pr.state || "").toUpperCase(),
    mergedAt: pr.merged_at ?? null,
    updatedAt: pr.updated_at ?? null,
    isCrossRepository: !!(headRepo && pr.base?.repo && headRepo.full_name !== pr.base.repo.full_name),
    headRepository: headRepo
      ? { id: headRepo.node_id, name: headRepo.name, nameWithOwner: headRepo.full_name }
      : null,
    headRepositoryOwner: headRepo?.owner
      ? { id: headRepo.owner.node_id, name: headRepo.owner.login, login: headRepo.owner.login }
      : null,
  };
}

function readCache(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function ageMs(file) {
  try {
    return Date.now() - statSync(file).mtimeMs;
  } catch {
    return Infinity;
  }
}

function atomicWrite(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, file);
}

function serve(list) {
  const out = (list || [])
    .filter((pr) => pr.headRefName === t3.head && stateMatches(pr.state, t3.state))
    .slice(0, 20);
  dbg(`SERVE head=${t3.head} state=${t3.state} matched=${out.length} of ${(list || []).length}`);
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

try {
  const remote = spawnSync("git", ["remote", "get-url", "origin"], { encoding: "utf8" }).stdout?.trim();
  const match = remote && remote.match(/github\.com[:/]([^/]+)\/(.+?)(?:\.git)?$/);
  if (!match) passthrough();

  const owner = match[1];
  const repo = match[2];
  mkdirSync(CACHE_DIR, { recursive: true });

  const base = join(CACHE_DIR, `${owner}__${repo}`);
  const dataFile = `${base}.json`;
  const etagFile = `${base}.etag`;

  const cached = readCache(dataFile);
  if (cached && ageMs(dataFile) < TTL_MS) serve(cached);

  const token = stripAnsi(spawnSync(REAL_GH, ["auth", "token"], { encoding: "utf8" }).stdout).trim();
  if (!token) {
    if (cached) serve(cached);
    passthrough();
  }

  const url = `https://api.github.com/repos/${owner}/${repo}/pulls?state=all&per_page=100`;
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: "application/vnd.github+json",
    "User-Agent": "gh-pr-shim",
    "X-GitHub-Api-Version": "2022-11-28",
  };

  const etag = existsSync(etagFile) ? readFileSync(etagFile, "utf8") : null;
  if (etag) headers["If-None-Match"] = etag;

  const response = await fetch(url, { headers });
  if (response.status === 304 && cached) {
    utimesSync(dataFile, new Date(), new Date());
    serve(cached);
  }

  if (response.status === 200) {
    const data = (await response.json()).map(mapPR);
    atomicWrite(dataFile, JSON.stringify(data));
    const nextEtag = response.headers.get("etag");
    if (nextEtag) atomicWrite(etagFile, nextEtag);
    serve(data);
  }

  if (cached) serve(cached);
  passthrough();
} catch {
  passthrough();
}
