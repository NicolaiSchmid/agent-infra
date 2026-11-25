# Canonical initial module upload

The release owner alone performs provider operations. Use exact reviewed Git
commit bytes, not a stale PR diff or a mutable raw branch URL. Require branch ref,
PR head and CI evidence to agree on the reviewed pin before staging. Recompute
module SHA-256 from that pin and record only the digest and version receipt in
the June ledger. This document is payload preparation, not a deployment receipt.

For initial **absent script** creation, use
`PUT /accounts/e32779e58e3407367e2454c3eebf20e9/workers/scripts/{scriptName}`,
Content-Type `multipart/form-data` with a transport-generated boundary:

| Script | JSON part `metadata` (application/json) | Module file part (application/javascript+module) |
| --- | --- | --- |
| june-ingress-preflight | preflight-upload-metadata.json | name and filename `preflight-worker.mjs`, exact file bytes |
| june-withdraw-deferred-content | withdrawal-upload-metadata.json | name and filename `withdrawal-worker.mjs`, exact file bytes |

Do not send the ES module as raw `application/javascript`; that upload format
supports legacy `addEventListener` scripts, not `export default`. The multipart
file name must match `metadata.main_module`. Do not encode the module as a JSON
string or substitute a source URL. If Executor's transport cannot produce the
required multipart parts faithfully, stop at that transport gate; do not fall back
to a provider CLI or switch formats.

The Cloudflare OpenAPI upload schema supports multipart module files,
`main_module`, `compatibility_date`, `bindings`, `observability.enabled`, `logpush`
and `tail_consumers`. The metadata files explicitly disable observability and
Logpush, with no tail consumers or initial bindings. **They are initial-creation
payloads only**: do not reuse `bindings:[]` after private dashboard secret entry,
which could remove the binding. Any later code/version update requires a separately
reviewed binding-preservation contract and readback, never retrieval of its value.

`workers_dev`, `preview_urls` and `routes` in Wrangler configs are not multipart
upload metadata. After initial upload and before route/DNS attachment, use
`POST /accounts/{account_id}/workers/scripts/{script_name}/subdomain` with
`{"enabled":false,"previews_enabled":false}`; the inspected OpenAPI supports both
fields. Verify disabled readback. Inspect settings metadata to confirm observability
and Logpush off, no tail consumers and no persistence bindings. Audit account-level
logging separately. Route-free configuration does not prove workers.dev was never
briefly enabled during creation; do not enter the private credential before the
subdomain/previews disable/readback gate.

The production and probe route fail mode is a **manual dashboard** control, not
an upload field: set each exact route to Fail closed and verify it before DNS.
See [the mandatory route failure gate](withdrawal-activation.md#fail-closed-route-prerequisite).
No `fail_open` or `failmode` API property is assumed. Private dashboard binding
entry and all audit/quota/TLS/browser gates remain as documented in the runbooks.
