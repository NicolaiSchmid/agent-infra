# Candidate ingress operations — not installed

This is the reviewable delta attached to the readiness ledger, not a deployment
receipt. The ledger owns live observations and release status. No operation here
restores June Git admission. No paid AuthKit domain is involved.

## Ownership and private execution contract

Permanent source home is `NicolaiSchmid/agent-infra/cloudflare/june-ingress/`;
DNS home is `NicolaiSchmid/dns` using its existing reconciliation workflow
([DNS draft #112](https://github.com/NicolaiSchmid/dns/pull/112)). This package is
preparation only; merging source does not authorize any provider write.
The sole live evidence/status ledger is
[June readiness ledger](https://github.com/NicolaiSchmid/june/blob/docs/junepartner-release-readiness/.plans/2026-11-04-junepartner-release-readiness.md)
via [June PR #979](https://github.com/NicolaiSchmid/june/pull/979).
Use the PR's current head if its branch changes. Record live receipts there,
not in this source package. Re-read every provider precondition before activation.

Executor is the only provider gateway. Do not use plaintext-return secret tools.
An automated transfer would require a proven audited private secretRef/internal
binding that never returns credential values in tool output. No such path is
proven by the scoped secret/vault/transfer namespace search; this does not mean
private transfer is globally unavailable. Saved provider connections are accessible.

The exact manual fallback, only after separate activation authorization: the user
opens Vercel dashboard → team `wasc` → project `june` → Settings → Deployment
Protection → Protection Bypass for Automation, generates a **new** credential named
`june-ingress-worker-only` (or equivalent ownership note if the UI uses notes),
and enters it **DIRECTLY** in Cloudflare dashboard → Workers & Pages → selected
Worker → Settings → Variables and Secrets → Add → type **Secret**, name
`VERCEL_AUTOMATION_BYPASS_SECRET`. Do this for `june-ingress-preflight` and
`june-withdraw-deferred-content`; save/deploy only in the separately authorized
sequence below. Never paste the value in chat, repo, shell, logs, a tool argument,
or a screenshot. The agent verifies binding name/type only. Do not use a plaintext
variable. Clear the local clipboard after entry. The credential remains project
scoped, not cryptographically Worker/path scoped; the name records its sole intended
consumer. If the dashboard cannot create a distinct named/noted credential without
replacing the unknown existing one, stop. Do not retrieve or revoke the existing
credential. Confirm successful private entry and probe result in the ledger.

Before generating anything, inspect June's existing bypass **metadata only**:
notes, scopes, creation dates and configured sharing exceptions through a metadata-only endpoint or a user dashboard audit. Do not call `projects.getProject`: its schema can include bypass-map secret keys and environment values, even if output would later be filtered. Identify owners
and consumers in deployment automation and secret stores through metadata/access
references. The existing single automation credential's ownership/sharing is not
yet established. Do not retrieve or revoke it. Prefer a distinct Worker-only
project credential with an ownership note; project scope still covers all June
deployments, so it is not a path-scoped credential. Inventory share links,
protection exceptions and previously issued bypass cookies as residual access
capabilities. An unknown exception is a release gate, not grounds for revocation.

## Fail-closed route prerequisite

For **each** production route (`dearjune.ai/*`, `www.dearjune.ai/*`) and probe
route (`ingress-preflight.dearjune.ai/*`), open Cloudflare dashboard → Workers &
Pages → selected Worker → Settings → Domains & Routes → the corresponding route;
set its route failure mode toggle to **Fail closed** (dashboard labels may vary).
Read it back for the exact route pattern and returned route ID; record nonsecret
metadata/user attestation in the June ledger. If the control cannot be located or
verified, stop. Do not invent an API `fail_open`/`failmode` field: the inspected
Workers OpenAPI request schema exposes no such setting.

[Cloudflare limits](https://developers.cloudflare.com/workers/platform/limits/)
documents Free 100,000 requests/day, reset at midnight UTC, quota error 1027,
Fail open bypassing the Worker and Fail closed returning 1027. Require dashboard
proof plus a safe isolated synthetic failure test/metadata proof approved by the
release owner; do not intentionally exhaust production quota. A configuration
screenshot must exclude secrets/cookies. All-deployment Vercel auth is additional
defense, but does not waive the explicit fail-closed boundary gate. If a safe test
cannot be arranged, leave validation unresolved. Set/read the toggle immediately
after each route creation and before its proxied DNS is created/changed.

## Exact guarded operations

Use IDs and patterns from `withdrawal-operations.json`. For every write, re-read
the object immediately, compare the expected fields, abort on drift, patch only
the named field, and read it back. Preserve complete private before snapshots
with credential values redacted from evidence. Record API request IDs and returned
route/version IDs, never request headers or bodies containing secrets.

1. Confirm June's assembled exact-head CI and parent release coordination; confirm
   Worker account plan, quota headroom and fail-closed quota behavior. No paid
   upgrade is authorized. Confirm Full (strict) TLS and an active edge certificate
   for each hostname before proxying it. Audit existing Cloudflare redirect rules:
   `nicool.ai` currently redirects and must retain that behavior; if redirects
   precede Workers, prove withdrawn requests still cannot reach Vercel. Otherwise
   omit that route until a reviewed redirect-rule delta exists.
2. `PUT /accounts/{accountId}/workers/scripts/june-withdraw-deferred-content`
   multipart module: `main_module=withdrawal-worker.mjs`, compatibility date
   `2026-11-04`, `observability.enabled=false`, no KV/R2/D1/queues/logpush bindings.
   Disable workers.dev and preview URLs via script subdomain settings. Disable
   sampling/tail consumers and inspect account-level logging rules; this module
   itself does not log, cache or store content. Retain script version ID.
3. Complete the private dashboard fallback above (or separately prove the audited
   private transfer contract). Binding name/type must be
   `VERCEL_AUTOMATION_BYPASS_SECRET` / `secret_text`; no value enters an API tool.
   Complete the isolated [protected-origin preflight](preflight.md) before any
   existing DNS/protection change. It creates only a temporary new hostname/script/route.
4. `POST /zones/{zoneId}/workers/routes` for each reviewed whole-host pattern:
   `{pattern, script: "june-withdraw-deferred-content"}`. Before creation assert no
   conflicting routes. Record returned route IDs for rollback. New junepartner www/apis hosts
   are excluded at this stage. Do not route wildcard subdomains or ownCloud.
5. `PATCH /zones/d286575216add73551f89a402e467168/dns_records/{recordId}` for the two
   dearjune records in the manifest with **only** `{"proxied":true}`. Preserve
   record type, name, content and all unrelated settings. Wait for authoritative
   and external resolver convergence and valid TLS; test both hosts while custom
   domains still have their prior Vercel protection policy. Test Worker marker on
   rejected paths and synthetic unaffected GET/POST, redirects and callback query
   preservation. If any test fails, restore the two original proxied fields and
   remove only newly created routes; do not enable all-deployment auth.
6. Require a passing isolated preflight receipt for the exact pinned deployment,
   binding and reviewed resource in [preflight.md](preflight.md). This proves
   private binding/access, not custom-host behavior. Step 5 must independently
   prove the final Worker's unaffected GET/POST, redirect and query behavior.
   Re-read June's protection mode using a secret-free metadata endpoint or user
   dashboard confirmation (never raw `projects.getProject`); require
   `ssoProtection.deploymentType=all_except_custom_domains`. Only under separate
   explicit live authorization execute the narrow write:
   `projects.updateProject({idOrName:"prj_XbkZ9JrnupD7Kf9Zpmz5OC3tkgsc",slug:"wasc",
   body:{ssoProtection:{deploymentType:"all"}}})`. Read back `all`; preserve every
   unrelated project field and deploymentPolicy. This protects direct aliases and
   custom-host direct-IP/SNI requests from unauthenticated application access.
7. Immediately test anonymous direct generated aliases, `nicoolai.vercel.app`,
   custom Host/SNI to Vercel, and every remaining June project domain: expect
   Vercel auth and no application handling. Test through edge: blocked methods
   reject with edge marker; unaffected routes remain accessible. Existing Vercel
   team sessions/bypass capabilities are privileged exceptions, not anonymous
   origin access. Once alias ownership/use is confirmed, retire only
   `nicoolai.vercel.app` with `removeProjectDomain`, without removing redirects
   or other aliases. Snapshot its full domain configuration first.
8. Browser acceptance through the edge must prove WorkOS login, callback code/state,
   refresh/logout, application session cookies and ordinary Convex browser calls;
   fetches must not receive Vercel SSO HTML. Inspect cookie attributes without
   recording values. Keep provided AuthKit and distinct Convex SDK origin. Verify
   www static assets, unrelated endpoints and legacy redirects. New www DNS is a
   separate assembled-release operation; never publish `apis` as this Worker.

## Rollback and availability

Before step 6, restoring original DNS proxied values and deleting only returned
new-route IDs restores the prior infrastructure (and prior unsafe ingress); it
is not an accepted withdrawal release. After step 6, **retain all-deployment
protection and Worker denial** while rolling back Worker code to a known-good
version. Restore the prior private binding if only the new binding is broken.
Never remove routes/proxy while origin remains protected: public traffic would
receive Vercel auth. Never disable protection as an automatic rollback: that
reopens withdrawn ingress. If no known-good Worker exists, keep origin protected
and accept a controlled outage pending release-owner decision. There is no
transaction across Cloudflare DNS, edge propagation and Vercel protection; zero
outage is a testable rollout objective, not a guarantee.

Exact policy reversal, only with explicit incident-owner approval acknowledging
reopened ingress: same `projects.updateProject` call with
`{ssoProtection:{deploymentType:"all_except_custom_domains"}}`, guarded on current
`all`. Read back, then restore DNS fields to `false`, delete only recorded new
route IDs, restore retired alias from its saved snapshot if required. Revoke a
new Worker-only credential only after proving no active Worker version or other
consumer uses it; never revoke the pre-existing credential blindly.

## Costs and limits

Vercel documents Vercel Authentication **All Deployments** and automation bypass
as included on all plans, without the paid protection add-on:
https://vercel.com/docs/deployment-protection/usage-and-pricing and
https://vercel.com/docs/deployment-protection . Password protection is not used.
Cloudflare Workers Free publishes 100,000 requests/day and 10 ms CPU/request;
paid starts at US$5/month with usage charges:
https://developers.cloudflare.com/workers/platform/pricing/ . Zone Website billing does not establish Workers account billing. See the June ledger for account read evidence. Confirm plan and fail-closed request-limit
behavior before installation; never allow quota exhaustion to bypass the Worker.

This restricts application forwarding and anonymous origin access. It cannot
prevent arbitrary hostile clients from sending bytes to Cloudflare or Vercel's
network/authentication boundary, and does not claim that it can.
