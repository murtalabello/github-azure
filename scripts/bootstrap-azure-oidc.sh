#!/usr/bin/env bash
# One-time setup of the GitHub <-> Azure trust for ONE environment.
# Run it once for dev and once for prod (each with its own subscription).
#
# What it creates / configures (idempotent — safe to re-run):
#   Azure (in the target subscription)
#     - rg-tfstate-<env> + locked-down storage account + "tfstate" container
#     - User-assigned managed identity "id-gh-<owner>-<repo>-<env>" (no Entra app registration / Graph rights needed)
#     - Federated credentials (OIDC, no secrets) for:
#         repo:<owner>/<repo>:environment:<env>   -> apply jobs
#         repo:<owner>/<repo>:pull_request         -> PR plan jobs
#         repo:<owner>/<repo>:ref:refs/heads/main  -> plan jobs on main
#     - RBAC: Contributor on the subscription, Storage Blob Data Contributor on the state account
#   GitHub
#     - Repo variables AZURE_TENANT_ID, AZURE_CLIENT_ID_<ENV>, AZURE_SUBSCRIPTION_ID_<ENV>
#     - Optional ADMIN_SSH_PUBLIC_KEY
#     - Environment <env> (prod: required reviewer + main-only deployments)
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

# ------------------------------------------------- user-assigned identity
# A user-assigned managed identity with federated credentials: same OIDC trust as an
# app registration, but created through ARM only — no Entra/Graph admin rights needed.
log "Managed identity: $IDENTITY_NAME"
if ! az identity show -n "$IDENTITY_NAME" -g "$STATE_RG" -o none 2>/dev/null; then
  az identity create -n "$IDENTITY_NAME" -g "$STATE_RG" -l "$LOCATION" \
    --tags purpose=github-oidc environment="$ENV_NAME" -o none
fi
APP_ID=$(az identity show -n "$IDENTITY_NAME" -g "$STATE_RG" --query clientId -o tsv)
SP_OBJ_ID=$(az identity show -n "$IDENTITY_NAME" -g "$STATE_RG" --query principalId -o tsv)
echo "client id: $APP_ID"

add_fic() {
  local name="$1" subject="$2"
  if az identity federated-credential show --name "$name" --identity-name "$IDENTITY_NAME" -g "$STATE_RG" -o none 2>/dev/null; then
    echo "federated credential '$name' exists"
    return
  fi
  az identity federated-credential create --name "$name" --identity-name "$IDENTITY_NAME" -g "$STATE_RG" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$subject" --audiences "api://AzureADTokenExchange" -o none
  echo "federated credential '$name' -> $subject"
}

log "Federated credentials"
# Names get a suffix when the subject uses immutable IDs, so both formats can coexist.
FIC_SUFFIX=""; [[ "$SUBJECT_REPO" != "$REPO" ]] && FIC_SUFFIX="-ids"
add_fic "gh-env-${ENV_NAME}${FIC_SUFFIX}" "repo:${SUBJECT_REPO}:environment:${ENV_NAME}"
add_fic "gh-pull-request${FIC_SUFFIX}"    "repo:${SUBJECT_REPO}:pull_request"
add_fic "gh-branch-main${FIC_SUFFIX}"     "repo:${SUBJECT_REPO}:ref:refs/heads/main"

# ---------------------------------------------------------------------- RBAC
assign() {
  local role="$1" scope="$2"
  for i in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$SP_OBJ_ID" --assignee-principal-type ServicePrincipal \
         --role "$role" --scope "$scope" -o none 2>/dev/null; then
      echo "role '$role' on $scope"; return
    fi
    # Usually SP replication lag right after creation.
    sleep $((i * 10))
  done
  echo "FAILED to assign '$role' on $scope" >&2; exit 1
}

log "Role assignments"
assign "Contributor" "/subscriptions/${SUB_ID}"
assign "Storage Blob Data Contributor" "$SA_ID"

# -------------------------------------------------------------------- GitHub
if [[ "$SKIP_GITHUB" == "true" ]]; then
  log "Skipping GitHub config (-G). Set these repo variables yourself:"
  echo "  AZURE_TENANT_ID=$TENANT_ID"
  echo "  AZURE_CLIENT_ID_${ENV_UPPER}=$APP_ID"
  echo "  AZURE_SUBSCRIPTION_ID_${ENV_UPPER}=$SUB_ID"
else
log "GitHub variables on $REPO"
gh variable set AZURE_TENANT_ID              --repo "$REPO" --body "$TENANT_ID"
gh variable set "AZURE_CLIENT_ID_${ENV_UPPER}"       --repo "$REPO" --body "$APP_ID"
gh variable set "AZURE_SUBSCRIPTION_ID_${ENV_UPPER}" --repo "$REPO" --body "$SUB_ID"
if [[ -n "$SSH_KEY_FILE" ]]; then
  gh variable set ADMIN_SSH_PUBLIC_KEY --repo "$REPO" --body "$(cat "$SSH_KEY_FILE")"
fi

log "GitHub environment: $ENV_NAME"
if [[ "$ENV_NAME" == "prod" ]]; then
  body=$(jq -n '{deployment_branch_policy:{protected_branches:false, custom_branch_policies:true}}')
  if [[ -n "$REVIEWER" ]]; then
    rid=$(gh api "users/${REVIEWER}" --jq .id)
    body=$(echo "$body" | jq --argjson id "$rid" '. + {reviewers:[{type:"User", id:$id}]}')
  fi
  echo "$body" | gh api -X PUT "repos/${REPO}/environments/prod" --input - >/dev/null
  gh api -X POST "repos/${REPO}/environments/prod/deployment-branch-policies" \
    -f name=main -f type=branch >/dev/null 2>&1 || true
  if [[ -z "$REVIEWER" ]]; then
    echo "NOTE: no reviewer given — add required reviewers on the prod environment in repo Settings > Environments."
  fi
else
  gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" >/dev/null
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
  client id       $APP_ID
  identity        $IDENTITY_NAME
  state account   $SA_NAME
EOF
