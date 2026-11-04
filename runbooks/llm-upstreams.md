# LLM upstream infrastructure

Use the existing NixOS host configuration and SOPS for runtime operations, and
OpenTofu for cloud resources. The implementation starts with Azure state storage,
a read-only GitHub planning identity and import of an existing inference account.
It creates nothing until an operator explicitly applies a reviewed plan.

The MODUS investigation records the wider decision and legal/runtime boundaries:
[upstream infrastructure proposal](https://github.com/NicolaiSchmid/june/pull/978).
This repository owns cloud and host configuration. The MODUS gateway owns model
routing, API adapters and admission of client traffic. A provisioned resource is
not an approved route.

## Current scope

- `nix develop .#cloud` supplies flake-pinned OpenTofu, Azure CLI, SOPS, age and Python.
- `cloud/llm/bootstrap/azure` creates state storage and GitHub OIDC trust with
  Reader access to the existing inference group, plus Blob lease/state access.
- `cloud/llm/azure` imports the observed Azure account through AzAPI without
  calling `listKeys`. It has no model deployments or automatic policy changes.
- Cloud CI validates offline with no Azure credentials. The manual plan workflow
  runs only from main and cannot apply. There is no unattended drift repair.
- `scripts/convex-provider-secrets.py` delivers supported vendor keys from
  protected files to the gateway's dev or prod Convex deployment. It does not
  create accounts, obtain keys, configure SOPS recipients or enable routes.

Google stacks and a dedicated Hetzner inference host follow when their actual
project, region, capacity and host requirements are known. Hetzner Cloud resources
can use a separate OpenTofu state; NixOS configures the host. Dedicated-server
ordering and initial installation require the supported Robot/provisioning flow.
Do not create empty cross-provider modules in advance.

## Inventory Azure without reading keys

Enter the cloud shell and use interactive Azure login. Select the intended
subscription explicitly; never copy a session or key from an old thread.

```sh
nix develop .#cloud
az login
az account set --subscription '<subscription-id>'
az cognitiveservices account list --query "[?name=='modusservice'].{id:id,name:name,location:location,kind:kind,sku:sku,tags:tags}" -o json
az cognitiveservices account show --resource-group '<group>' --name modusservice --query '{id:id,location:location,kind:kind,sku:sku,tags:tags,properties:properties}' -o json
az cognitiveservices account deployment list --resource-group '<group>' --name modusservice -o json
```

These management operations do not invoke the separate key-list endpoint. Keep
full inventory private: management metadata can still be operationally sensitive.
Inspect effective `ContentLogging=false`, network/local-auth settings, model
versions, deployment SKUs, RAI policies and allocated quota. Approval emails do
not prove the effective configuration. Do not change filters because permission
to modify them exists. EU-only inference needs supported EU Data Zone or regional
deployments; a European account with a Global deployment is insufficient.

## Bootstrap state storage and CI trust

This incurs Azure storage costs and changes IAM. Review the real subscription,
region, names, scope and costs before executing. No placeholder example is ready
to apply. Account/resource-provider registration is a separate operator step:
bootstrap intentionally disables automatic registration. Ensure Storage,
ManagedIdentity and CognitiveServices are registered as needed.

1. Configure a recovery age recipient and independently backed-up human/admin
   access. Do not rely on the host SSH key as the sole recovery path.
2. Make a private operator directory with mode `0700`, set `umask 077`, and copy
   the bootstrap `.tf` and lock file there. Local bootstrap state is sensitive;
   AzureRM may record storage keys even when shared-key access is disabled.
   Do not use a public CI runner/artifact for bootstrap.
3. Copy `terraform.example.tfvars` to `terraform.tfvars`, replace every placeholder
   and run `tofu init`, `tofu plan -out=bootstrap.tfplan`. Review privately, then
   apply that exact plan only after authorization. The operator needs management
   rights to create storage/identity and assign the documented roles, and suitable
   Blob data access for subsequent backend migration. Never grant CI Owner.
4. Retain the public backend identifiers and separately protected bootstrap state.
   To move bootstrap state to Blob, add `backend "azurerm" { use_azuread_auth = true }`
   inside its terraform block in the private operator copy, then run
   `tofu init -migrate-state -backend-config=bootstrap.tfbackend`. Use a distinct
   key `llm/bootstrap/azure.tfstate`; verify lineage/serial and a clean plan before
   removing local state/plan copies. Persist that backend declaration in a reviewed
   follow-up PR once the real backend exists so future operators use it consistently.
5. Blob versioning and soft delete are enabled. Configure independently protected
   off-account backup/retention and test recovery before making this production
   infrastructure. LRS on its own is not disaster recovery.

State and saved plans must be treated as secrets even when outputs are redacted.
Storage encryption is at rest; it does not keep state secret from authorized
readers. OpenTofu client-side state encryption can be added with a separately
recoverable key if required. It is not configured in this first slice.

## Import the existing account

Copy the account `.tf` files and lock file into a private operator directory.
Fill `backend.example.tfbackend` and `terraform.example.tfvars` from inventory.
The account body must contain **observed writable** settings, not the entire ARM
response: omit read-only capabilities, endpoints and provisioning metadata.
Record current network, local-auth and custom-domain settings explicitly; do not
adopt permissive defaults just to make the plan pass.

```sh
tofu init -backend-config=backend.tfbackend
tofu plan -var-file=terraform.tfvars -out=import.tfplan
```

Accept only an import with **zero additions, changes or destructions**. If there
is a mismatch, correct the configuration and re-plan; do not apply to normalize
unknown settings. The account is protected against deletion. Apply the reviewed
import plan, inspect state privately for unexpected sensitive fields, and require
a second normal plan with no changes. Model deployments are deliberately left
unmanaged until inventoried; do not delete/recreate them or adopt defaults.

## GitHub planning workflow

After bootstrap and the reviewed import, configure environment `llm-cloud-plan`
with required reviewers and deployment branches restricted to main. Supply these
**nonsecret** environment variables from the real reviewed configuration:

- `AZURE_PLAN_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- `AZURE_BACKEND_CONFIG`: backend HCL with the account state's key
- `AZURE_ACCOUNT_CONFIG`: JSON object matching the account stack variables,
  including the observed writable account body

Never put API keys/private keys in these variables. OIDC trust is restricted to
this exact repository/environment. The identity can read the inference group but
cannot change its cloud resources. Blob Data Contributor is required for leases
and also permits state writes: environment access therefore remains privileged.
Trigger **Azure cloud plan** from main. It reports only clean/import-or-drift/fail,
withholds detailed output and uploads no plan artifacts. Investigate details in a
private operator session. A later protected apply workflow needs its own narrowly
scoped identity and review; this foundation deliberately has no apply identity.

## Deliver T-Systems and IONOS credentials

Keep authoritative values SOPS-encrypted with the host and recovery recipients.
No real values are included here. The decrypted JSON object may contain
`TSYSTEMS_API_KEY_SECONDARY` and/or `IONOS_API_KEY`, each a nonempty string.
Use only credentials appropriate for the selected deployment. The secondary
T-Systems key is the existing synthetic route; IONOS delivery does not add an
IONOS gateway adapter or route. Verify the gateway's typed env contract before use.

On the operator/target host, decrypt into a restricted temporary directory rather
than Nix evaluation or command arguments:

```sh
umask 077
credential_dir=$(mktemp -d)
trap 'rm -rf "$credential_dir"' EXIT
sops --decrypt --output-type json secrets/llm-providers.enc.json > "$credential_dir/providers.json"
python3 scripts/convex-provider-secrets.py --deployment dev \
  --secrets-file "$credential_dir/providers.json" \
  --admin-key-file '<protected-dev-admin-key-file>' --check
# After reviewing the exact deployment, repeat without --check to deliver.
```

The encrypted file must first be created through the normal SOPS process with
verified recipients. The delivery command refuses symlinks, non-owner or
world/group-readable input, unknown variables and redirects; it never logs server
responses or values. It updates only named variables, preserving other deployment
env. The API shape matches Convex's `callUpdateEnvironmentVariables` operation;
validate with a synthetic credential on dev before production use. HTTPS endpoints
are fixed in the script; review that mapping when moving the inference host.

Do not run under shell tracing. Convex admin credentials grant broad access and
must never enter the provider JSON or GitHub configuration. Convex env values
persist server-side and may be in backups; host Compose env is a different layer.
Avoid copying them to Vercel. Rotation is replacement → SOPS update → delivery →
synthetic health check → revocation of old credential. Provider-side issuance and
revocation stay manual until a supported API is verified. This tool intentionally
has no read-back/dump operation.

## Recovery and future deployment

Recover with an independent authorized human identity. Restore a known Blob
version to a new key, check state lineage and actual resources, then perform a
private reviewed refresh/plan. Never force-unlock a lease until its owner is dead.
If state is gone, inventory/import is the last resort. Preserve encrypted backups
and their decryption/recovery keys separately; Git alone is not enough.

Before applying a new Azure deployment, review concrete model/version, EU SKU,
region, allocated capacity, RAI/monitoring and price. Run synthetic conformance
from self-hosted Convex; client content must never flow through Vercel. Certificate
or federated runtime auth is separate from GitHub OIDC and needs its own tested
credential lifecycle. Contract incorporation/intermediary coverage and effective
retention settings remain gates before confidential client traffic.
