# Azure VMs with Terraform + GitHub Actions

This repo builds Linux VMs in Azure for two environments, **dev** and **prod**, each in its own
Azure subscription. GitHub Actions runs Terraform. There are **no passwords or secrets** stored
anywhere: GitHub proves who it is to Azure with a short-lived token (OIDC).

## The big picture

```
 You push to main
        │
        ▼
 ┌──────────────────────┐   1. "I am repo X, branch main"    ┌──────────────────────────┐
 │ GitHub Actions job   │ ─────── (GitHub OIDC token) ─────▶ │ Microsoft Entra ID       │
 │ (vm-deploy.yml)      │                                    │ checks the token against │
 │                      │ ◀────── 2. Azure access token ──── │ the managed identity's   │
 └──────────┬───────────┘                                    │ "federated credentials"  │
            │ 3. terraform plan / apply                      └──────────────────────────┘
            ▼
 ┌─────────────────────────────── one Azure subscription per environment ─────────────────┐
 │  rg-tfstate-<env>                         rg-app-<env>-vm                               │
 │   ├─ storage account (Terraform state)     ├─ virtual network + subnet + NSG            │
 │   └─ managed identity id-gh-…-<env>        ├─ network interface(s)                      │
 │      (what GitHub signs in as)             └─ Linux VM(s)  (private IP only)            │
 └─────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Setup pieces** (`rg-tfstate-<env>`) were created once by `scripts/bootstrap-azure-oidc.sh`.
- **The VMs and network** (`rg-app-<env>-vm`) are created by Terraform from this repo.
- **Which subscription** a job talks to depends only on the GitHub variables for that environment.

## The three pipelines

| Pipeline | When it runs | dev | prod |
|---|---|---|---|
| **vm-deploy** | Pull request to `main` | plan (posted as a PR comment) | plan (posted as a PR comment) |
| **vm-deploy** | Push / merge to `main` | plan → **apply** | plan only (nothing changes) |
| **vm-deploy** | Run workflow by hand | plan or apply | plan, or apply after **your approval** |
| **vm-destroy** | Run workflow by hand only | destroy | destroy after **your approval** |

Every run first **plans** (shows what would change), then **applies exactly that saved plan**.
If the plan has no changes, the apply step is skipped.

## Common tasks

All of these are in the repo's **Actions** tab → pick the workflow → **Run workflow**.

| I want to… | Do this |
|---|---|
| Change dev (size, count, OS…) | Edit `infra/vm/env/dev.tfvars`, open a PR, read the plan comment, merge. |
| Deploy prod | `vm-deploy` → environment `prod`, action `apply` → approve when asked. |
| See what prod would change | `vm-deploy` → environment `prod`, action `plan`. |
| Delete an environment's VMs | `vm-destroy` → pick the environment, type its name again in **confirm**. |
| Approve a prod run | Open the run → **Review deployments** → tick `prod` → **Approve and deploy**. |

`vm-destroy` removes the VMs, network and resource group `rg-app-<env>-vm`. It does **not**
touch the Terraform state storage or the sign-in setup, so you can deploy again any time.

## Current status

| | dev | prod |
|---|---|---|
| VMs | ✅ `vm-app-dev-01` (`Standard_B2s`, 10.10.1.4) | ⏸ not deployed: waiting for Azure quota |
| Network | ✅ created | — none (removed with `vm-destroy`; `vm-deploy` apply recreates it) |

**Why prod is paused:** the prod subscription has **0 vCPU quota** for the `Standard DSv5`
family in South Central US, and prod uses two `Standard_D2s_v5` VMs (4 vCPUs total). Once the
quota request is approved (Azure portal → Subscriptions → *prod* → **Usage + quotas** → limit ≥ 4),
run `vm-deploy` with environment `prod` and action `apply`. No code changes are needed.

## Where things are configured

```
infra/vm/env/dev.tfvars        ← dev sizing, VM count, network ranges
infra/vm/env/prod.tfvars       ← prod sizing, VM count, network ranges
infra/vm/env/*.backend.hcl     ← where each environment keeps its Terraform state
infra/vm/main.tf               ← resource group, network, NSG, and the VM module call
modules/vm/                    ← the VM itself (Linux or Windows)
.github/workflows/vm-deploy.yml             ← deploy pipeline (triggers + dev/prod order)
.github/workflows/vm-destroy.yml            ← destroy pipeline
.github/workflows/terraform-vm-reusable.yml ← the shared plan → approve → apply steps
scripts/bootstrap-azure-oidc.sh             ← one-time Azure/GitHub sign-in setup
```

**GitHub repo variables** (Settings → Secrets and variables → Actions → Variables). These are
IDs, not secrets:

| Variable | Value |
|---|---|
| `AZURE_TENANT_ID` | `a0859c2c-6006-4f6c-8e7f-69a8fca8a849` |
| `AZURE_SUBSCRIPTION_ID_DEV` | `4db12431-b606-4b3d-a0bf-da48a2913526` |
| `AZURE_CLIENT_ID_DEV` | `e53e62b3-39e3-403a-870c-a2fc8d05169d` (identity `id-gh-murtalabello-github-azure-dev`) |
| `AZURE_SUBSCRIPTION_ID_PROD` | `184d2ede-e572-4d93-95bd-bfd15f8f9d24` |
| `AZURE_CLIENT_ID_PROD` | `3663ea7b-1640-4fb6-9a22-4ac9b4c8eb2a` (identity `id-gh-murtalabello-github-azure-prod`) |
| `ADMIN_SSH_PUBLIC_KEY` | public key installed on the Linux VMs (user `azureadmin`) |

**GitHub environments** (Settings → Environments): `dev` (no approval) and `prod` (requires your
approval). Apply and destroy jobs run inside these environments.

## How sign-in works

Each managed identity trusts GitHub tokens only when the token's **subject** matches one of its
federated credentials. This repo's tokens use GitHub's ID-based subject format:

| Job | Subject GitHub sends | Allowed by |
|---|---|---|
| Plan on `main` | `repo:murtalabello@61387158/github-azure@1410712234:ref:refs/heads/main` | dev + prod identities |
| Plan on a PR | `repo:murtalabello@61387158/github-azure@1410712234:pull_request` | dev + prod identities |
| Apply / destroy | `repo:murtalabello@61387158/github-azure@1410712234:environment:<env>` | only that environment's identity |

Permissions given to each identity: **Contributor** on its own subscription, and **Storage Blob Data
Contributor** on its own state storage account. The dev identity cannot touch prod, and the prod
identity cannot touch dev.

## Accessing the VMs

The VMs have **no public IP** and the NSG allows **no inbound admin traffic** by default. To get in,
either:

- use **Azure Bastion** on the VNet, or
- set `admin_source_cidrs = ["<your-ip>/32"]` and `create_public_ip = true` in the tfvars file
  (fine for dev; not recommended for prod).

Log in as `azureadmin` with the private key that matches `ADMIN_SSH_PUBLIC_KEY`.

## Troubleshooting

| Error in the run | Meaning | Fix |
|---|---|---|
| `AADSTS700213: No matching federated identity record` | The token's subject isn't trusted by the identity. | Add a federated credential with the subject printed by the *Check Azure sign-in and state access* step. |
| `exceeding approved … Cores quota` | The subscription isn't allowed that many vCPUs of that VM family in that region. | Request a quota increase, or pick a different `vm_size` in the tfvars file. |
| State container returned HTTP 403 | The identity can't read the state storage. | Give the identity **Storage Blob Data Contributor** on the state storage account. |
| Prod job stuck on *Waiting* | It needs approval. | Open the run → **Review deployments** → approve `prod`. |

## Setting this up from scratch (another repo or subscription)

Run once per environment, from the repo root, logged in with `az` as an Owner of that subscription:

```bash
./scripts/bootstrap-azure-oidc.sh -e dev  -s <DEV_SUBSCRIPTION_ID>  -r <owner>/<repo> -S '<owner>@<owner-id>/<repo>@<repo-id>'
./scripts/bootstrap-azure-oidc.sh -e prod -s <PROD_SUBSCRIPTION_ID> -r <owner>/<repo> -S '<owner>@<owner-id>/<repo>@<repo-id>' -p <github-reviewer>
```

It creates the state storage, the managed identity, its federated credentials and permissions,
the GitHub variables and environments, and fills in `infra/vm/env/<env>.backend.hcl`. Pass `-G`
to skip the GitHub part and set the variables yourself. Leave out `-S` if the repo's tokens use
the plain `repo:<owner>/<repo>:…` subject format.
