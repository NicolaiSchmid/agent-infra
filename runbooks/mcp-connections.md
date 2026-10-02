# MCP connections (June gateway)

All MCP servers reach the agents (Claude Code, Codex, T3 Code, Hermes) through
**one gateway: June** at `https://www.dearjune.ai/api/mcp`. Do not wire
individual MCP servers into client configs; connect the service in June once
and it is available to every agent and to June's own loop.

Design and status: `nicoolai/.plans/2026-10-01-june-mcp-gateway.md`.
Cutover state (2026-10-02): the June endpoint ships in the PR "June as the one
MCP gateway" (#551). Until that PR is deployed, `https://executor.sh/nicolai-schmid/mcp`
(Executor Cloud) is still the live gateway; it is closed once every client below
is moved.

## Client setup

Auth is OAuth against June's WorkOS AuthKit (Dynamic Client Registration and
Client ID Metadata Documents are enabled in the dearJune Production
environment; the resource indicator is `https://www.dearjune.ai/api/mcp`).

```sh
# Claude Code
claude mcp add --transport http june https://www.dearjune.ai/api/mcp -s user
# Codex
codex mcp add june --url https://www.dearjune.ai/api/mcp
codex mcp login june
```

Codex: set `tool_timeout_sec = 300` under `[mcp_servers.june]` in
`~/.codex/config.toml`; integration calls can exceed the 60 s default.
T3 Code inherits the config of the agent it hosts. Remove the old `executor`
entry from `~/.claude.json` and `~/.codex/config.toml` after the first
successful `execute` call.

## Using the gateway from an agent session

Two tools: `skills` (how-to plus the live connector inventory for the signed-in
June user) and `execute({ code })`, TypeScript against the `tools` proxy:

```ts
// discover, then call by full address
const { items } = await tools.search({ query: "posthog query" });
await tools.describe.tool({ path: items[0].path });
await tools[items[0].path]({ ... });
// add a remote MCP server from the session
await tools.executor.mcp.addServer({ transport: "remote", name: "...", endpoint: "https://.../mcp" });
```

Connections are per June user and are managed in June (Settings → Integrations)
or by the connect link
`https://www.dearjune.ai/api/integrations/oauth/start?integration=<slug>&redirectTo=/dashboard/integrations`
that `execute` returns when a call hits a missing or expired connection. There
are no approvals on this surface; calls run as the signed-in user.

## Connections that matter per project

Registered in Nicolai's June account on 2026-10-02 (all OAuth, authorise once
via the connect link):

| Service | June slug | Scope / notes |
| --- | --- | --- |
| WorkOS | `mcp_workos_com` | One connection per WorkOS team: dearJune (June / nicoolai), fifthset (project `project_01M17PHKZ48KF4AFT7GZBHB2M1`, prod env `environment_01M17PHMGQN6FBX7MGR9NNH1TG`, owns the FifthSet JWT template), Nunc (Nunc / Mietprofi). Name connections after the team. |
| PostHog | `mcp_posthog_com` | One login, many orgs. `exec` tool: `switch-organization` then `switch-project` before project-scoped calls. dearJune = 217098, FifthSet = 261148, Nunc = 13059, Mietprofi = 253630. |
| Neon | `mcp_neon_tech` | accounts `apex` and `nicolai@schmid.uno`. |
| Attio | `mcp_attio_com` | workspaces `drio`, `nicolai-ai`. |
| Cal.com | `mcp_cal_com` | personal. |
| Apify | `mcp_apify_com` | personal. |
| Cloudflare | `mcp_cloudflare_com` | personal. |
| Cosma | `cosma_app` | cosmo. |
| Linkup | `mcp_linkupapi_com` | nicolai. |
| Jamie | `mcp_meetjamie_ai` | personal. |
| Stripe | `mcp_stripe_com` | mosaic. |
| Subzero | `www_subzero_to` | drio. |
| Mosaic | `mosaic_nicolaischmid_com` | already in June. |

Not yet in June: `vercel` (team `wasc`, API key) and `documenso_v2_api` were
OpenAPI integrations on Executor Cloud; they come back through the vendors'
MCP servers or `@executor-js/plugin-openapi` when first missed.

WorkOS MCP usage: `list_operations` (optionally `{operation}` for parameters),
`query {operation, environment_id, variables}` and `mutate {...}`. JWT
templates: `jwtTemplate` / `jwtTemplateContent` (read), `validateJwtTemplate`,
`previewJwtTemplate` (render for a real user id), `upsertJwtTemplate`,
`deleteJwtTemplate`. Environment ids come from `dashboardSession`; do not
confuse `environment_…` with `client_…` ids.
