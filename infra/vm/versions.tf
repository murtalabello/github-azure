terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Partial config — the per-environment values live in env/<env>.backend.hcl
  # and are passed with: terraform init -backend-config=env/<env>.backend.hcl
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}

# Auth comes from the environment (set by the workflow):
#   ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_USE_OIDC=true
# The subscription is therefore chosen per environment without touching code.
provider "azurerm" {
  features {}
  use_oidc            = true
  storage_use_azuread = true
}
