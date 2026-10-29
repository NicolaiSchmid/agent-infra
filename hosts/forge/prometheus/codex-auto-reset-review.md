# Codex Auto Reset review (2026-10-29)

Reviewed release: `v0.1.13` of JefferyZhang2019/cpa-plugin-codex-auto-reset.
The release tree matches reviewed commit `7aee5a1df1a360e4db33a05df0ccd19f104c2770`.

The plugin reads Codex credentials through the host ABI. Production HTTP
requests go to `https://chatgpt.com/backend-api/wham/` for usage, credit
inventory, and targeted redemption. No shell execution, external telemetry,
or credential logging was found in the reviewed production paths. Its UI
calls same-origin management routes; mutating routes require management auth.
State contains configuration, scheduling observations, and audit history,
not access or refresh tokens.

Redemption selects the earliest-expiring available credit, revalidates it at
the trigger time, and sends both `credit_id` and `redeem_request_id`. Retries
reuse that request ID. After redemption it checks inventory and recovered
quota, then clears CLIProxy's cached routing cooldown on verified success.

Validation: upstream tests with Go's race detector, `go vet`, the simulation
suite, and additional simulated three-minute and fifteen-minute triggers all passed. The
timing tests confirm no early consumption and leaves a later credit
untouched. No real reset credit was consumed during validation.

Limitations:

- Worker restart does not restore the complete in-flight attempt despite
  comments suggesting crash resumption. Credit targeting limits damage, but
  do not reconfigure/restart while redeeming or verifying.
- `Stop` signals shutdown without joining the old worker. Avoid repeated
  reconfiguration during redemption.
- A failed confirmation waits until the next patrol. Use a five-minute patrol
  with the fifteen-minute lead time; outages and retry delays can still cause
  credits to expire unused.
- Persisted settings take precedence over YAML after initial setup. Change
  the existing installation through the plugin settings API or panel too.

Deployment uses a checksum-pinned release, only explicitly selected Codex
accounts, and state under the existing persistent auth volume. These tests
do not establish a guarantee of successful redemption against future API changes.

Live validation: the first automatic redemption was verified at 20:13 Berlin
on 2026-10-29, restoring weekly remaining quota from 0% to 100% and reducing
available credits from two to one. Scheduling was subsequently changed to
a fifteen-minute lead time with five-minute checks.
