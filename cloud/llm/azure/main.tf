terraform {
  required_version = ">= 1.10, < 2.0"
  backend "azurerm" {
    use_azuread_auth = true
  }
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azapi" {
  subscription_id            = var.subscription_id
  skip_provider_registration = true
}

variable "subscription_id" { type = string }
variable "resource_group_name" { type = string }
variable "account_name" { type = string }
variable "location" { type = string }
variable "account_body" {
  type        = any
  description = "Reviewed writable ARM properties from inventory; never include credentials or read-only capabilities."
}
variable "tags" { type = map(string) }

locals {
  api_version = "2024-10-01"
  account_id  = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.CognitiveServices/accounts/${var.account_name}"
}

# Standard ARM GET/PUT only. No listKeys action or AzureRM account key exports.
resource "azapi_resource" "account" {
  type                   = "Microsoft.CognitiveServices/accounts@${local.api_version}"
  name                   = var.account_name
  parent_id              = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  location               = var.location
  tags                   = var.tags
  body                   = var.account_body
  response_export_values = ["properties.endpoint"]
  lifecycle { prevent_destroy = true }
}

import {
  to = azapi_resource.account
  id = "${local.account_id}?api-version=${local.api_version}"
}

output "endpoint" { value = azapi_resource.account.output.properties.endpoint }
