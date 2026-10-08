# Azure VM — Terraform + GitHub Actions (dev / prod, OIDC)

One Terraform root, one workflow, two environments in **two subscriptions**.
GitHub authenticates to Azure with **OIDC workload identity federation** — no client secrets anywhere.

```
modules/vm/                         # VM module (Linux or Windows via os_type)
infra/vm/                           # root config that calls the module
  env/dev.tfvars   env/prod.tfvars          # per-env sizing / network
  env/dev.backend.hcl env/prod.backend.hcl  # per-env state (in each env's own subscription)
.github/workflows/vm-deploy.yml             # triggers + dev -> prod promotion
.github/workflows/terraform-vm-reusable.yml # plan -> approval -> apply (one env)
scripts/bootstrap-azure-oidc.sh             # one-time GitHub <-> Azure trust setup
```

> **Using your existing module:** if your module lives somewhere else, change `source` in `infra/vm/main.tf`
> and map the inputs. This root expects the module to accept `name, resource_group_name, location, subnet_id,
> os_type, size, os_disk_type, zone, create_public_ip, admin_username, admin_ssh_public_key, admin_password, tags`
> and output `vm_id, vm_name, private_ip_address, public_ip_address`.

## How the pipeline flows

| Trigger | dev | prod |
|---|---|---|
| PR to `main` | plan (comment on PR) | plan (comment on PR) |
| Merge / push to `main` | plan → apply | plan → **approval** → apply (runs after dev succeeds) |
| Run workflow (manual) | plan / apply / destroy | plan / apply / destroy (approval on apply/destroy) |

- Apply always uses the **saved plan** from the plan job — what reviewers approve is exactly what runs.
- Apply is skipped when the plan has no changes.
- `destroy` needs the `confirm` input set to the environment name.
- One state lock per env via `concurrency` + blob lease.

## How auth works

```
GitHub job ──OIDC token (sub = repo:OWNER/REPO:...)──▶ managed identity "id-gh-OWNER-REPO-<env>"
                                                        │  federated credential matches sub
                                                        ▼
                                          access token for that env's subscription
```

| Job | Token subject | Trusted by |
|---|---|---|
| PR plan | `repo:OWNER/REPO:pull_request` | dev + prod identities |
| plan on `main` | `repo:OWNER/REPO:ref:refs/heads/main` | dev + prod identities |
| apply | `repo:OWNER/REPO:environment:dev` / `:prod` | only that env's identity |

**Subjects with immutable IDs.** GitHub may issue subjects as `repo:OWNER@<owner-id>/REPO@<repo-id>:...`
(this repo does: `repo:murtalabello@61387158/github-azure@1410712234:...`). Azure must trust that exact form,
or sign-in fails with `AADSTS700213`. Pass it to the bootstrap script with `-S 'OWNER@<id>/REPO@<id>'`; the
workflow's *Check Azure sign-in and state access* step prints the subject GitHub actually sends.

The workflow picks the identity with `ARM_CLIENT_ID` / `ARM_SUBSCRIPTION_ID` per environment; Terraform's azurerm
provider and backend do the OIDC exchange themselves (`ARM_USE_OIDC=true`), so no `azure/login` step is needed.

## Setup (once)

Prereqs: `az` logged in as Owner (or Contributor + User Access Administrator) on each subscription; `gh` logged in with admin on the repo; `jq`.

```bash
# from the repo root
chmod +x scripts/bootstrap-azure-oidc.sh

./scripts/bootstrap-azure-oidc.sh -e dev  -s <DEV_SUBSCRIPTION_ID>  -r murtalabello/github-azure -k ~/.ssh/id_rsa.pub
./scripts/bootstrap-azure-oidc.sh -e prod -s <PROD_SUBSCRIPTION_ID> -r murtalabello/github-azure -p <github-reviewer-login>

git add infra/vm/env/*.backend.hcl && git commit -m "Configure Terraform state backends" && git push
```

That creates, per env: state storage (shared keys disabled, versioning + soft delete), a user-assigned
managed identity (no Entra app registration or Graph rights needed), three federated credentials, RBAC, GitHub repo variables, and the GitHub environment
(prod: required reviewer, `main` only).

**Repo variables it sets** (Settings → Secrets and variables → Actions → Variables):

| Variable | Example |
|---|---|
| `AZURE_TENANT_ID` | tenant GUID |
| `AZURE_CLIENT_ID_DEV` / `AZURE_CLIENT_ID_PROD` | app (client) IDs |
| `AZURE_SUBSCRIPTION_ID_DEV` / `AZURE_SUBSCRIPTION_ID_PROD` | subscription IDs |
| `ADMIN_SSH_PUBLIC_KEY` | Linux VMs only |

These are identifiers, not secrets, so variables are fine.

### Manual setup (if you can't run the script)

Per environment, in that env's subscription:
1. Create a user-assigned managed identity `id-gh-<owner>-<repo>-<env>` in `rg-tfstate-<env>`.
2. Identity → Federated credentials → *GitHub Actions deploying Azure resources*: add the three
   subjects in the table above (entity types *Environment*, *Pull request*, *Branch = main*).
3. Subscription → IAM → **Contributor** to the identity. State storage account → IAM → **Storage Blob Data Contributor**.
4. Add the repo variables above, and create GitHub environments `dev` and `prod` (prod: required reviewers,
   deployment branches = `main`).

## Day-to-day

- Change sizing / OS / count in `infra/vm/env/<env>.tfvars`, open a PR, read both plans, merge.
- Switch to Windows: `os_type = "windows"` — a password is generated and available via
  `terraform output -raw windows_admin_password` (it lives in state; move it to Key Vault if people need it).
- No inbound admin access by default. Set `admin_source_cidrs` or use Azure Bastion.

## Hardening options

- Swap subscription-wide **Contributor** for Contributor scoped to the VM resource group (pre-create the RG) or a
  custom role.
- Give PR plans a separate **Reader** identity so a PR can't write to prod even if the workflow is edited in the PR.
- Add a `CODEOWNERS` entry for `.github/workflows/` and `infra/`, and branch protection on `main`.
- Add `tflint` / `checkov` steps before plan.

## Current deployment (murtalabello/github-azure)

| | dev | prod |
|---|---|---|
| Subscription | `4db12431-b606-4b3d-a0bf-da48a2913526` | `184d2ede-e572-4d93-95bd-bfd15f8f9d24` |
| Identity client ID | `e53e62b3-39e3-403a-870c-a2fc8d05169d` | `3663ea7b-1640-4fb6-9a22-4ac9b4c8eb2a` |
| State account | `sttfstatedevb0e407` | `sttfstateprod9da4cd` |
| Tenant | `a0859c2c-6006-4f6c-8e7f-69a8fca8a849` | same |
