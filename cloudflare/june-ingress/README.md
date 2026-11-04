# June ingress source candidate

Preparation only. No deploy workflow, route attachment, provider writes or live
activation is included. `withdrawal-worker.mjs` is ported from June PR #979 commit
`45f994872`, including decoded `#`/`?` normalization and `cacheTtl: -1`.

- [Guarded activation and rollback](withdrawal-activation.md)
- [Isolated protected-origin preflight](preflight.md)
- [Canonical initial multipart upload and config audit](upload.md)
- [Exact operation inputs](withdrawal-operations.json)
- [Sole live readiness ledger / PR](https://github.com/NicolaiSchmid/june/pull/979)

The two Wrangler JSON files disable workers.dev, preview URLs and observability.
Their empty route lists intentionally attach nothing. They are source configuration,
not permission to run Wrangler. Bind `VERCEL_AUTOMATION_BYPASS_SECRET` only as an
encrypted secret through the documented private dashboard path. No secret value
belongs in these files. Check platform tail/logpush/account logging and fail-closed
quota behavior before installation. No storage bindings are defined. Existing
Cache Rules must not override the no-cache subrequest setting; verify at activation.

Run dependency-free scoped checks with Node 22 or newer:

```sh
node --test cloudflare/june-ingress/*.test.mjs
```

The public final Worker allows only dearjune.ai and www.dearjune.ai. It rejects
withdrawn paths for every method before body consumption or upstream fetch, retains
unaffected request bodies and ordinary query bytes, and handles redirects manually.
The isolated probe has a different hostname and fixed upstream; it never returns
upstream content, headers or cookies. Neither Worker uses content logging, Cache API,
KV, R2 or other persistence. Transient bounded favicon hashing is probe-only.

nicool.ai redirects, ownCloud, Convex SDK/HTTP origins, gateway and AuthKit are
excluded. Source/DNS/protection changes remain release-owner gates; no paid upgrade
or secret retrieval/revocation is authorized by this package.
