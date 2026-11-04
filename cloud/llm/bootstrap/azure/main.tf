terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  storage_use_azuread             = true
  resource_provider_registrations = "none"
}

variable "subscription_id" {
  type = string
}
variable "location" {
  type        = string
  description = "State-storage region chosen by the operator. Does not select inference geography."
}
variable "resource_group_name" {
  type = string
}
variable "storage_account_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Use a globally unique Azure storage name with 3–24 lowercase letters/digits."
  }
}
variable "github_repository" {
  type        = string
  description = "Exact owner/repository receiving plan access, e.g. NicolaiSchmid/agent-infra."
}
variable "github_environment" {
  type        = string
  description = "Protected GitHub environment used by the manual read-only plan job."
}
variable "inference_resource_group_id" {
  type        = string
  description = "Existing inference resource group to grant Reader access. No cloud write permission."
}

resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location
  lifecycle { prevent_destroy = true }
}

resource "azurerm_storage_account" "state" {
  name                            = var.storage_account_name
  resource_group_name             = azurerm_resource_group.state.name
  location                        = azurerm_resource_group.state.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  blob_properties {
    versioning_enabled = true
    delete_retention_policy { days = 30 }
    container_delete_retention_policy { days = 30 }
  }
  lifecycle { prevent_destroy = true }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
  lifecycle { prevent_destroy = true }
}

resource "azurerm_user_assigned_identity" "plan" {
  name                = "llm-cloud-plan"
  resource_group_name = azurerm_resource_group.state.name
  location            = azurerm_resource_group.state.location
}

resource "azurerm_federated_identity_credential" "github_plan" {
  name                = "github-plan"
  resource_group_name = azurerm_resource_group.state.name
  parent_id           = azurerm_user_assigned_identity.plan.id
  issuer              = "https://token.actions.githubusercontent.com"
  audience            = ["api://AzureADTokenExchange"]
  subject             = "repo:${var.github_repository}:environment:${var.github_environment}"
}

resource "azurerm_role_assignment" "plan_reader" {
  scope                = var.inference_resource_group_id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.plan.principal_id
}

# Blob Contributor is needed for the state lease even for a read-only cloud plan.
resource "azurerm_role_assignment" "plan_state" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.plan.principal_id
}

output "backend" {
  value = {
    resource_group_name  = azurerm_resource_group.state.name
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azurerm_storage_container.state.name
  }
}
output "plan_client_id" { value = azurerm_user_assigned_identity.plan.client_id }
output "tenant_id" { value = azurerm_user_assigned_identity.plan.tenant_id }
