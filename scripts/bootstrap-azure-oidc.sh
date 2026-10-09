#!/usr/bin/env bash
# One-time setup of the GitHub <-> Azure trust for ONE environment.
# Run it once for dev and once for prod (each with its own subscription).
#
# What it creates / configures (idempotent — safe to re-run):
#   Azure (in the target subscription)
#     - rg-tfstate-<env> + locked-down storage account + "tfstate" container
#     - Two user-assigned managed identities (no Entra app registration / Graph rights needed):
#         id-gh-<owner>-<repo>-<env>       apply identity: Contributor on the subscription +
#                                          Storage Blob Data Contributor on the state account.
#                                          Trusts only  repo:<owner>/<repo>:environment:<env>
#         id-gh-<owner>-<repo>-<env>-plan  plan identity (read-only): Reader on the subscription +
#                                          Storage Blob Data Reader on the state account.
#                                          Trusts  repo:<owner>/<repo>:ref:refs/heads/main
#                                          and     repo:<owner>/<repo>:pull_request
#   GitHub
#     - Repo variables AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID_<ENV>,
#       AZURE_CLIENT_ID_<ENV> (apply) and AZURE_CLIENT_ID_PLAN_<ENV> (plan)
#     - Optional ADMIN_SSH_PUBLIC_KEY
#     - Environment <env>, deployable from main only (prod: plus a required reviewer)
#   Repo files
#     - infra/vm/env/<env>.backend.hcl
#
# Prereqs: az CLI (logged in as someone who can create resources and
# assign roles — Owner or User Access Administrator on the subscription),
# gh CLI (logged in with admin on the repo; or pass -G to skip GitHub config), jq.
#
# Usage (from the repo root):
#   ./scripts/bootstrap-azure-oidc.sh -e dev  -s <dev-sub-id>  -r owner/repo [-l southcentralus] [-k ~/.ssh/id_rsa.pub]
#   ./scripts/bootstrap-azure-oidc.sh -e prod -s <prod-sub-id> -r owner/repo -p <github-reviewer-login>
#
# -S <subject-repo>: the repo part of the OIDC subject, when GitHub issues tokens with
#   immutable IDs, e.g. -S 'owner@123/repo@456' for 'repo:owner@123/repo@456:...'.
#   The workflow's "Check Azure sign-in" step prints the subject GitHub actually sends.
set -euo pipefail

LOCATION="southcentralus"
REVIEWER=""
SSH_KEY_FILE=""
SKIP_GITHUB="false"
SUBJECT_REPO=""
ENV_NAME=""
SUB_ID=""
REPO=""

usage() { sed -n '2,30p' "$0"; exit 1; }

while getopts "e:s:r:l:p:k:S:Gh" opt; do
  case $opt in
    e) ENV_NAME="$OPTARG" ;;
    s) SUB_ID="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    l) LOCATION="$OPTARG" ;;
    p) REVIEWER="$OPTARG" ;;
    k) SSH_KEY_FILE="$OPTARG" ;;
    G) SKIP_GITHUB="true" ;;
    S) SUBJECT_REPO="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$ENV_NAME" || -z "$SUB_ID" || -z "$REPO" ]] && usage
SUBJECT_REPO="${SUBJECT_REPO:-$REPO}"
[[ "$ENV_NAME" =~ ^(dev|prod)$ ]] || { echo "env must be dev or prod"; exit 1; }
for bin in az jq; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done

ENV_UPPER=$(echo "$ENV_NAME" | tr '[:lower:]' '[:upper:]')
IDENTITY_NAME="id-gh-${REPO//\//-}-${ENV_NAME}"
PLAN_IDENTITY_NAME="${IDENTITY_NAME}-plan"
STATE_RG="rg-tfstate-${ENV_NAME}"

log() { printf '\n==> %s\n' "$*"; }

log "Selecting subscription $SUB_ID"
az account set --subscription "$SUB_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)

# ---------------------------------------------------------------- state store
log "Terraform state: $STATE_RG"
az group create -n "$STATE_RG" -l "$LOCATION" --tags purpose=tfstate environment="$ENV_NAME" -o none

SA_NAME=$(az storage account list -g "$STATE_RG" --query "[?tags.purpose=='tfstate'].name | [0]" -o tsv)
if [[ -z "$SA_NAME" ]]; then
  SA_NAME="sttfstate${ENV_NAME}$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n' | cut -c1-6)"
  az storage account create -n "$SA_NAME" -g "$STATE_RG" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --https-only true \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --tags purpose=tfstate environment="$ENV_NAME" -o none
fi
SA_ID=$(az storage account show -n "$SA_NAME" -g "$STATE_RG" --query id -o tsv)

az storage account blob-service-properties update --account-name "$SA_NAME" -g "$STATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 -o none

# Control-plane create, so no data-plane role is needed for the person running this.
az storage container-rm create --storage-account "$SA_NAME" -g "$STATE_RG" -n tfstate -o none 2>/dev/null || true
echo "storage account: $SA_NAME"

# ------------------------------------------------- user-assigned identities
# User-assigned managed identities with federated credentials: same OIDC trust as an
# app registration, but created through ARM only — no Entra/Graph admin rights needed.
ensure_identity() {
  local name="$1"
  if ! az identity show -n "$name" -g "$STATE_RG" -o none 2>/dev/null; then
    az identity create -n "$name" -g "$STATE_RG" -l "$LOCATION" \
      --tags purpose=github-oidc environment="$ENV_NAME" -o none
  fi
}

add_fic() {
  local identity="$1" name="$2" subject="$3"
  if az identity federated-credential show --name "$name" --identity-name "$identity" -g "$STATE_RG" -o none 2>/dev/null; then
    echo "federated credential '$name' on $identity exists"
    return
  fi
  az identity federated-credential create --name "$name" --identity-name "$identity" -g "$STATE_RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$subject" --audiences "api://AzureADTokenExchange" -o none
  echo "federated credential '$name' on $identity -> $subject"
}

assign() {
  local principal="$1" role="$2" scope="$3"
  for i in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
         --role "$role" --scope "$scope" -o none 2>/dev/null; then
      echo "role '$role' on $scope"; return
    fi
    # Usually identity replication lag right after creation.
    sleep $((i * 10))
  done
  echo "FAILED to assign '$role' on $scope" >&2; exit 1
}

# Names get a suffix when the subject uses immutable IDs, so both formats can coexist.
FIC_SUFFIX=""; [[ "$SUBJECT_REPO" != "$REPO" ]] && FIC_SUFFIX="-ids"

log "Apply identity: $IDENTITY_NAME"
ensure_identity "$IDENTITY_NAME"
APP_ID=$(az identity show -n "$IDENTITY_NAME" -g "$STATE_RG" --query clientId -o tsv)
SP_OBJ_ID=$(az identity show -n "$IDENTITY_NAME" -g "$STATE_RG" --query principalId -o tsv)
add_fic "$IDENTITY_NAME" "gh-env-${ENV_NAME}${FIC_SUFFIX}" "repo:${SUBJECT_REPO}:environment:${ENV_NAME}"
assign "$SP_OBJ_ID" "Contributor" "/subscriptions/${SUB_ID}"
assign "$SP_OBJ_ID" "Storage Blob Data Contributor" "$SA_ID"

log "Plan identity (read-only): $PLAN_IDENTITY_NAME"
ensure_identity "$PLAN_IDENTITY_NAME"
PLAN_APP_ID=$(az identity show -n "$PLAN_IDENTITY_NAME" -g "$STATE_RG" --query clientId -o tsv)
PLAN_OBJ_ID=$(az identity show -n "$PLAN_IDENTITY_NAME" -g "$STATE_RG" --query principalId -o tsv)
add_fic "$PLAN_IDENTITY_NAME" "gh-branch-main${FIC_SUFFIX}"  "repo:${SUBJECT_REPO}:ref:refs/heads/main"
add_fic "$PLAN_IDENTITY_NAME" "gh-pull-request${FIC_SUFFIX}" "repo:${SUBJECT_REPO}:pull_request"
assign "$PLAN_OBJ_ID" "Reader" "/subscriptions/${SUB_ID}"
assign "$PLAN_OBJ_ID" "Storage Blob Data Reader" "$SA_ID"

# -------------------------------------------------------------------- GitHub
if [[ "$SKIP_GITHUB" == "true" ]]; then
  log "Skipping GitHub config (-G). Set these repo variables yourself:"
  echo "  AZURE_TENANT_ID=$TENANT_ID"
  echo "  AZURE_CLIENT_ID_${ENV_UPPER}=$APP_ID"
  echo "  AZURE_CLIENT_ID_PLAN_${ENV_UPPER}=$PLAN_APP_ID"
  echo "  AZURE_SUBSCRIPTION_ID_${ENV_UPPER}=$SUB_ID"
else
log "GitHub variables on $REPO"
gh variable set AZURE_TENANT_ID              --repo "$REPO" --body "$TENANT_ID"
gh variable set "AZURE_CLIENT_ID_${ENV_UPPER}"       --repo "$REPO" --body "$APP_ID"
gh variable set "AZURE_CLIENT_ID_PLAN_${ENV_UPPER}"  --repo "$REPO" --body "$PLAN_APP_ID"
gh variable set "AZURE_SUBSCRIPTION_ID_${ENV_UPPER}" --repo "$REPO" --body "$SUB_ID"
if [[ -n "$SSH_KEY_FILE" ]]; then
  gh variable set ADMIN_SSH_PUBLIC_KEY --repo "$REPO" --body "$(cat "$SSH_KEY_FILE")"
fi

log "GitHub environment: $ENV_NAME (deployable from main only)"
body=$(jq -n '{deployment_branch_policy:{protected_branches:false, custom_branch_policies:true}}')
if [[ "$ENV_NAME" == "prod" && -n "$REVIEWER" ]]; then
  rid=$(gh api "users/${REVIEWER}" --jq .id)
  body=$(echo "$body" | jq --argjson id "$rid" '. + {reviewers:[{type:"User", id:$id}]}')
fi
echo "$body" | gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" --input - >/dev/null
gh api -X POST "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" \
  -f name=main -f type=branch >/dev/null 2>&1 || true
if [[ "$ENV_NAME" == "prod" && -z "$REVIEWER" ]]; then
  echo "NOTE: no reviewer given — add required reviewers on the prod environment in repo Settings > Environments."
fi
fi

# ----------------------------------------------------------- backend config
BACKEND_FILE="infra/vm/env/${ENV_NAME}.backend.hcl"
if [[ -d infra/vm/env ]]; then
  cat > "$BACKEND_FILE" <<EOF
# Written by scripts/bootstrap-azure-oidc.sh — lives in the ${ENV_UPPER} subscription.
resource_group_name  = "${STATE_RG}"
storage_account_name = "${SA_NAME}"
container_name       = "tfstate"
key                  = "vm/${ENV_NAME}.tfstate"
EOF
  log "Wrote $BACKEND_FILE — commit it."
fi

log "Done: $ENV_NAME"
cat <<EOF
  tenant          $TENANT_ID
  subscription    $SUB_ID
  apply identity  $IDENTITY_NAME  (client id $APP_ID)
  plan identity   $PLAN_IDENTITY_NAME  (client id $PLAN_APP_ID)
  state account   $SA_NAME
EOF
