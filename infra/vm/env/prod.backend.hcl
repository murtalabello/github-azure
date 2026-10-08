# Written by scripts/bootstrap-azure-oidc.sh — lives in the PROD subscription.
resource_group_name  = "rg-tfstate-prod"
storage_account_name = "sttfstateprod9da4cd"
container_name       = "tfstate"
key                  = "vm/prod.tfstate"
