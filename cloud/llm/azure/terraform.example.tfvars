# Copy observed writable settings exactly before planning an import.
subscription_id     = "<subscription-id>"
resource_group_name = "<existing-group>"
account_name        = "modusservice"
location            = "<observed-location>"
tags                = {}
account_body = {
  kind = "<observed-kind>"
  sku  = { name = "<observed-sku>" }
  properties = {
    # Populate observed writable network/auth/custom-domain settings.
    # Do not copy read-only capabilities, endpoints, provisioning state or keys.
  }
}
