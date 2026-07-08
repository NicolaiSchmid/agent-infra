# Secrets

Runtime secrets are managed with SOPS and `sops-nix`.

The public repo should contain only encrypted SOPS files. The first bootstrap
can work without this file, but before enabling automatic Tailscale enrollment
or backups, create `secrets.yaml` with entries such as:

```yaml
tailscale:
  black-authkey: ENC[...]
  atlas-authkey: ENC[...]
```

The target hosts decrypt secrets with their SSH host Ed25519 keys. Nicolai's
local age identity can also be added as a recipient for editing.
