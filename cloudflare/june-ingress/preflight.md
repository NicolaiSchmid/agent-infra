# Isolated protected-origin preflight — not authorized for installation

This is an exact candidate operation, not a live success receipt. Live evidence,
metadata observations, hashes and release decisions belong only in the
[June readiness ledger / PR #979](https://github.com/NicolaiSchmid/june/pull/979).
The initially proposed `june-9g2vqr95t-wasc.vercel.app` must not be used: revalidate
its state, and stop if BLOCKED. Never dispatch a deployment to make this probe work.

The replacement reviewed pin is deployment `dpl_RFh7EJZVmaRxCB2g4AEFNUEVrKwy`,
`https://june-mqsea5c26-wasc.vercel.app/favicon.ico`, June project
`prj_XbkZ9JrnupD7Kf9Zpmz5OC3tkgsc`, team `wasc`. Before installation repeat
Executor `deployments.getDeployment({idOrUrl:"june-mqsea5c26-wasc.vercel.app",slug:"wasc"})`:
require exact ID/URL/project and READY, not deleted or retained-away. This endpoint
contains deployment metadata, not project bypass maps; never call raw
`projects.getProject` or environment/secret retrieval APIs. Confirm protection with
an anonymous cookie-free request (no redirect following): require Vercel SSO
redirect, never application 200. Record only status and redirect hostname, no
Set-Cookie or nonce values.

Verify `deployments.listDeploymentFiles` for this deployment identifies
`/src/apps/june/public/favicon.ico` as a file, content ID
`4e95dfead6da3e0cfa613e53e50feb668920afc0`. The reviewed public source asset with
that SHA-1 has 15086 bytes and SHA-256
`3a6c67ab3abcf4f39dbc1970267c6963279d7f48aa5d24b965b37e76999e0cd8`.
Require expected origin status 200 and exact bytes/SHA-256. Source metadata is
not proof the protected HTTP response matches: that is what the probe must test.
Abort on drift and review a new exact pin; never substitute a mutable alias.

## Separately authorized creation sequence

Use Executor only for provider calls; no calls below have been executed by this
source work. Account `e32779e58e3407367e2454c3eebf20e9`, zone
`d286575216add73551f89a402e467168`. Coordinate the temporary declaration with
existing DNS draft #112 and its reconciliation owner; do not create another DNS PR
or unmanaged drift. Confirm quota headroom, fail-closed route behavior, Full (strict)
TLS, certificate coverage and no account logging/tail consumers first.

1. Re-read scripts, DNS records and Worker routes. Require script
   `june-ingress-preflight`, hostname `ingress-preflight.dearjune.ai` and any
   overlapping route all absent. If any exists, stop; do not overwrite it. Capture
   only nonsecret before metadata and absence evidence in the ledger.
2. `PUT /accounts/{accountId}/workers/scripts/june-ingress-preflight`: multipart
   `preflight-worker.mjs`, metadata `main_module=preflight-worker.mjs`,
   `compatibility_date=2026-11-04`, `observability.enabled=false`, no storage bindings.
   Disable workers.dev and previews with script subdomain settings
   `{enabled:false,previews_enabled:false}`; confirm readback, logging/tail disabled.
   Retain script/version IDs. Do not execute Wrangler deploy from this source PR.
3. User enters the new named Worker-only Vercel automation bypass **directly** into
   encrypted binding `VERCEL_AUTOMATION_BYPASS_SECRET` for probe and final Worker,
   following [private dashboard handling](withdrawal-activation.md). Confirm only
   name/type and user completion. No plaintext-return tool, env read or existing
   credential retrieval/revocation. If distinct generation would replace the
   unknown credential, stop.
4. Reassert route absence. `POST /zones/{zoneId}/workers/routes` with
   `{pattern:"ingress-preflight.dearjune.ai/*",script:"june-ingress-preflight"}`.
   Record returned route ID and verify exact readback. Set and read back **Fail
   closed** for this exact route in the dashboard before DNS creation, following
   [the route failure prerequisite](withdrawal-activation.md#fail-closed-route-prerequisite).
   No OpenAPI fail-mode field is assumed; safe isolated synthetic proof remains
   required, never deliberate production quota exhaustion. Whole-host routing makes
   other paths/methods reach the probe's local deny, not an origin fallback.
5. Reassert hostname absence. `POST /zones/{zoneId}/dns_records` with
   `{type:"AAAA",name:"ingress-preflight.dearjune.ai",content:"100::",ttl:1,proxied:true}`.
   This reserved discard address is never an application origin. Record returned
   record ID and exact readback. Obtain TLS/DNS convergence for this new host only;
   abort/clean up if a redirect rule intercepts it or TLS cannot validate.
6. With no cookies, credentials or query, GET and HEAD
   `https://ingress-preflight.dearjune.ai/__june_ingress_probe`. Require 200,
   `X-June-Ingress-Probe: pass`, `Cache-Control: no-store`, no Set-Cookie, GET's
   fixed `Protected origin probe passed` response and empty HEAD body. Internally
   both perform a fixed GET to the pinned favicon, only the private header,
   `redirect:manual`, `cacheEverything:false`, `cacheTtl:-1`; exact size/hash and
   absence of origin Set-Cookie must match. No content/header/cookie is returned or
   logged. Unexpected status/hash/size, redirect or fetch error returns generic 502.
7. Check POST/OPTIONS, different path, trailing slash and any query return 404 with
   probe deny marker. Unit tests prove these paths never fetch/consume a body;
   platform evidence must corroborate this without enabling content logging.
   Recheck anonymous direct origin remains Vercel-protected. Record pass/fail,
   IDs, version, expected digest and timestamp only in the ledger.
8. Clean up the temporary resources using the rollback below even after success.
   A successful probe is evidence of private binding and protected-origin access,
   not proof of final custom-host routing, WorkOS/session/callback/browser behavior.
   All final browser, assembled CI, quota, DNS and protection gates remain.

## Exact cleanup / rollback

Keep a creation journal; on any failure clean only completed newly-created objects.
Re-read each object by returned ID and require it still matches this operation.
Delete the new DNS record via `DELETE /zones/{zoneId}/dns_records/{newRecordId}`,
then the new route via `DELETE /zones/{zoneId}/workers/routes/{newRouteId}`,
then the new script via
`DELETE /accounts/{accountId}/workers/scripts/june-ingress-preflight` after proving
it has no other consumers/routes. Confirm absence. If drift appears, stop and
escalate to release owner rather than delete another owner's object. Removing the
route exposes only the reserved discard origin for this disposable hostname.
Never touch existing dearjune DNS/protection/aliases in probe cleanup. The final
Worker secret is retained; revoke the new project credential only with owner
approval after proving no active Worker version/other consumer uses it. Never
revoke the unknown existing credential. No protection rollback is needed for this
isolated probe because it never changes project protection.
