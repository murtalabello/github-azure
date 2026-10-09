# Azure VMs with Terraform + GitHub Actions

This repo creates Linux virtual machines in Azure for two environments, **dev** and **prod**.
Each environment lives in **its own Azure subscription**. GitHub Actions runs Terraform to
create, change and delete them.

**No passwords, keys or client secrets are stored in GitHub.** GitHub proves who it is to Azure
with a short-lived token that it gets fresh for every job (this is called OIDC).

Contents:

1. [Everything that exists, and who creates it](#1-everything-that-exists-and-who-creates-it)
2. [How it is all wired together](#2-how-it-is-all-wired-together)
3. [Everything stored in GitHub (variables, environments, secrets)](#3-everything-stored-in-github)
4. [The pipelines](#4-the-pipelines)
5. [Common tasks](#5-common-tasks)
6. [Current status](#6-current-status)
7. [Deleting everything, completely](#7-deleting-everything-completely)
8. [Setting it up again from zero](#8-setting-it-up-again-from-zero)
9. [Troubleshooting](#9-troubleshooting)
10. [Files in this repo](#10-files-in-this-repo)

---

## 1. Everything that exists, and who creates it

There are **two layers**. This is the most important thing to understand.

| Layer | What it is | Created by | Deleted by `vm-destroy`? |
|---|---|---|---|
| **A. Foundation** | Terraform state storage, the identity GitHub signs in as, its permissions, GitHub settings | **Once, by hand**: `scripts/bootstrap-azure-oidc.sh` (Azure CLI + GitHub CLI). **Not Terraform.** | **No.** It must survive, because Terraform needs it to run at all. |
| **B. Workload** | The VMs and their network | **Terraform**, run by GitHub Actions | **Yes** |

Why is the foundation not in Terraform? Terraform needs somewhere to keep its state file and
some identity to sign in with *before* it can create anything. So those have to exist first.
This is the usual "chicken and egg" setup for Terraform.

### Layer A: the foundation (one-time setup, **not** Terraform)

Created once per environment, inside that environment's subscription.

| Resource | dev | prod | What it is for |
|---|---|---|---|
| Resource group | `rg-tfstate-dev` | `rg-tfstate-prod` | Holds the two items below. Region: South Central US. |
| Storage account | `sttfstatedevb0e407` | `sttfstateprod9da4cd` | Stores the Terraform **state file** (Terraform's record of what it created). Locked down: no public access, no shared keys (sign-in only), TLS 1.2+, file versioning and 30-day soft delete so a bad change can be undone. |
| Blob container | `tfstate` | `tfstate` | The folder inside the storage account. State file: `vm/dev.tfstate` / `vm/prod.tfstate`. |
| User-assigned managed identity | `id-gh-murtalabello-github-azure-dev` | `id-gh-murtalabello-github-azure-prod` | **The Azure "user" that GitHub Actions signs in as.** It has no password. |
| Federated credentials (on the identity) | 6 | 6 | The rules that say *which* GitHub jobs may sign in as this identity. See [section 2](#2-how-it-is-all-wired-together). |
| Role: **Contributor** on the whole subscription | ✅ | ✅ | Lets the identity create and delete resources (VMs, networks…) in its own subscription. |
| Role: **Storage Blob Data Contributor** on the storage account | ✅ | ✅ | Lets the identity read and write the state file. |
| Resource providers registered | Compute, Network, Storage, ManagedIdentity (+ others Terraform registered on its first run) | same | A subscription must "switch on" a service before using it. One-time and free. |

The dev identity has **no** permissions in the prod subscription, and the prod identity has
**no** permissions in the dev subscription.

Also part of the foundation, on the GitHub side (details in [section 3](#3-everything-stored-in-github)):
repo **variables** and the **dev** / **prod** environments.

### Layer B: the workload (created by Terraform)

Created by `vm-deploy` and deleted by `vm-destroy`. Defined in `infra/vm/main.tf` and `modules/vm/`.

| Resource | dev | prod | Notes |
|---|---|---|---|
| Resource group | `rg-app-dev-vm` | `rg-app-prod-vm` | Everything below goes in here. |
| Virtual network | `vnet-app-dev` (10.10.0.0/16) | `vnet-app-prod` (10.20.0.0/16) | Private network for the VMs. |
| Subnet | `snet-vm` (10.10.1.0/24) | `snet-vm` (10.20.1.0/24) | |
| Network security group (firewall) | `nsg-app-dev-vm` | `nsg-app-prod-vm` | **Blocks all inbound access by default.** Opens SSH (port 22) only if you set `admin_source_cidrs`. |
| Firewall-to-subnet link | ✅ | ✅ | Applies the NSG to the subnet. |
| Network interface (per VM) | `vm-app-dev-01-nic` | `vm-app-prod-01-nic`, `vm-app-prod-02-nic` | Gives each VM its private IP. |
| Virtual machine | `vm-app-dev-01` (1 × `Standard_B2s`) | `vm-app-prod-01`, `vm-app-prod-02` (2 × `Standard_D2s_v5`, zones 1 and 2) | Ubuntu 22.04 LTS. Login user `azureadmin`, **SSH key only** (password login disabled). |
| OS disk (per VM) | `vm-app-dev-01-osdisk` (Standard SSD) | `…-osdisk` (Premium SSD) | Created and deleted together with its VM. |
| VM's own identity | System-assigned | System-assigned | Lets the VM itself be given Azure access later. Has no permissions now. |
| Public IP | **none** | **none** | Only created if `create_public_ip = true`. |

Dev resources: 7. Prod resources: 9 (two VMs and two NICs instead of one).
All sizes, counts and address ranges come from `infra/vm/env/dev.tfvars` and `infra/vm/env/prod.tfvars`.

---

## 2. How it is all wired together

### The sign-in chain, step by step

```
 ┌────────────────────────┐
 │ GitHub Actions job     │ 1. Reads the repo variables for this environment
 │                        │    (tenant ID, subscription ID, identity client ID)
 └───────────┬────────────┘
             │ 2. Asks GitHub for an OIDC token. GitHub signs a token that says, for example:
             │    "this is repo murtalabello/github-azure, running on branch main"
             ▼
 ┌────────────────────────┐ 3. Terraform sends that token to Microsoft Entra ID and says
 │ Microsoft Entra ID     │    "I want to act as identity <client ID>".
 │ (Azure sign-in)        │ 4. Entra checks the identity's federated credentials: is there a rule
 │                        │    whose subject matches what the token says? If not, sign-in fails
 └───────────┬────────────┘    (AADSTS700213). If yes, it hands back an Azure access token.
             │ 5. With that Azure token, Terraform:
             ▼
 ┌──────────────────────────────────────── that environment's subscription ──────────────┐
 │  a) reads/writes the state file in sttfstate…  (Storage Blob Data Contributor role)   │
 │  b) creates/changes/deletes rg-app-<env>-vm and everything in it  (Contributor role)   │
 └────────────────────────────────────────────────────────────────────────────────────────┘
```

Nothing in this chain is a stored secret. The GitHub token lasts minutes and only works for that
one job. The Azure token lasts about an hour.

### Which jobs are allowed to sign in (federated credentials)

GitHub puts a **subject** in every token that describes the job. Each identity has rules listing
the subjects it trusts. This repo's tokens use GitHub's **ID-based** subject format
(`murtalabello@61387158/github-azure@1410712234`, where the numbers are the owner and repo IDs).

| Credential name | Subject it trusts | Which jobs this lets in |
|---|---|---|
| `gh-branch-main-ids` | `repo:murtalabello@61387158/github-azure@1410712234:ref:refs/heads/main` | **Plan** jobs running from `main` |
| `gh-pull-request-ids` | `repo:murtalabello@61387158/github-azure@1410712234:pull_request` | **Plan** jobs on pull requests |
| `gh-env-dev-ids` / `gh-env-prod-ids` | `repo:murtalabello@61387158/github-azure@1410712234:environment:dev` (or `:prod`) | **Apply and destroy** jobs (they run inside a GitHub environment) |
| `gh-branch-main`, `gh-pull-request`, `gh-env-<env>` | same as above but `repo:murtalabello/github-azure:…` | **Unused.** Old name-based format, created first. Harmless; safe to delete. |

The pipelines only **apply** to prod from a job inside the `prod` environment, which waits for
your approval.

> **⚠️ Security limit: read this.** The approval protects the *pipeline*, not the *identity*. Plan
> jobs (on `main` and on pull requests) sign in as the **same** identity that has **Contributor**
> on the prod subscription. So anyone with **write access to this repo** could open a pull request
> that edits a workflow file to run commands against prod, without any approval. (Pull requests
> from **forks** cannot: GitHub does not give them sign-in tokens.) To close this gap, either:
> - give plan jobs a separate identity that only has **Reader** on the subscription plus
>   **Storage Blob Data Reader** on the state (two extra variables and a small workflow change), or
> - delete the `gh-pull-request*` credentials from the prod identity, so pull requests cannot
>   sign in to prod at all (PRs then only plan dev), and
> - protect `main` with a branch rule that requires a review before merging.

### How the workflow passes the settings to Terraform

In `.github/workflows/terraform-vm-reusable.yml`, the repo variables become environment variables
that Terraform's Azure provider reads automatically:

| Terraform reads | Filled from | Means |
|---|---|---|
| `ARM_TENANT_ID` | `vars.AZURE_TENANT_ID` | Which Entra tenant to sign in to |
| `ARM_SUBSCRIPTION_ID` | `vars.AZURE_SUBSCRIPTION_ID_DEV` or `_PROD` | Which subscription to build in |
| `ARM_CLIENT_ID` | `vars.AZURE_CLIENT_ID_DEV` or `_PROD` | Which identity to act as |
| `ARM_USE_OIDC=true` | fixed | Sign in with the GitHub token (not a password) |
| `ARM_USE_AZUREAD=true` | fixed | Use sign-in (not storage keys) for the state file |
| `TF_VAR_admin_ssh_public_key` | `vars.ADMIN_SSH_PUBLIC_KEY` | The SSH public key put on the Linux VMs |

The environment chosen by the pipeline (dev or prod) decides which `_DEV` / `_PROD` values are
used. That is the **only** thing that points a run at one subscription or the other.

The state file location comes from `infra/vm/env/<env>.backend.hcl`, passed to `terraform init`.

### How plan → approval → apply works

1. **Plan job** signs in, runs `terraform plan`, saves the plan file, and uploads it to the run
   as an artifact named `tfplan-vm-<env>` (kept for 1 day).
2. If the plan has **no changes**, the apply job is skipped.
3. **Apply job** runs inside the GitHub environment (`dev` or `prod`). For prod, GitHub pauses here
   until you approve.
4. Apply downloads **the exact plan file** from step 1 and applies it. So what you reviewed is
   exactly what happens. If something changed in the meantime, Terraform refuses the stale plan.
5. Only one run per environment at a time (GitHub `concurrency` group), and Terraform also locks
   the state file while it works.

---

## 3. Everything stored in GitHub

### Repository variables (Settings → Secrets and variables → Actions → **Variables**)

These are **IDs, not secrets**. Knowing them does not let anyone sign in. Sign-in only works
from this repo's own workflow jobs, because of the federated credentials.

| Variable | Value | Used for |
|---|---|---|
| `AZURE_TENANT_ID` | `a0859c2c-6006-4f6c-8e7f-69a8fca8a849` | Both environments |
| `AZURE_SUBSCRIPTION_ID_DEV` | `4db12431-b606-4b3d-a0bf-da48a2913526` | dev subscription |
| `AZURE_CLIENT_ID_DEV` | `e53e62b3-39e3-403a-870c-a2fc8d05169d` | client ID of `id-gh-murtalabello-github-azure-dev` |
| `AZURE_SUBSCRIPTION_ID_PROD` | `184d2ede-e572-4d93-95bd-bfd15f8f9d24` | prod subscription |
| `AZURE_CLIENT_ID_PROD` | `3663ea7b-1640-4fb6-9a22-4ac9b4c8eb2a` | client ID of `id-gh-murtalabello-github-azure-prod` |
| `ADMIN_SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA… muri@SandboxHost…` | **Public** half of the SSH key put on the VMs |

### Repository secrets (Settings → Secrets and variables → Actions → **Secrets**)

**None.** There are no client secrets, passwords, storage keys or private keys in GitHub.

### Tokens GitHub creates automatically for each run (nothing to store)

| Token | What it does |
|---|---|
| OIDC token (`id-token: write`) | Proves to Azure which repo/branch/environment the job is. Exchanged for an Azure token. |
| `GITHUB_TOKEN` (`contents: read`, `pull-requests: write`) | Lets the job check out the code and post the plan as a PR comment. |

### GitHub environments (Settings → **Environments**)

| Environment | Protection | Used by |
|---|---|---|
| `dev` | None: applies run straight away | dev apply and destroy jobs |
| `prod` | **Required reviewer: `murtalabello`.** Every prod apply/destroy waits for approval. | prod apply and destroy jobs |

Recommended extra: in the `prod` environment, set **Deployment branches** to `main` only, so a
workflow on another branch can never even ask for prod approval.

### Where the actual secrets are (outside GitHub)

| Secret | Where it is |
|---|---|
| SSH **private** key matching `ADMIN_SSH_PUBLIC_KEY` | Only where it was created (`~/.ssh/id_ed25519` in Azure Cloud Shell). It is not in GitHub or Azure. **If it is lost, nobody can SSH into the VMs.** Keep a copy somewhere safe. |
| Windows admin password (only if `os_type = "windows"`) | Generated by Terraform and kept in the **Terraform state file** (and in the plan artifact for up to 1 day). Read it with `terraform output -raw windows_admin_password`. |
| Terraform state file | `sttfstate…/tfstate/vm/<env>.tfstate`. Can only be read by the GitHub identity and subscription owners. |

---

## 4. The pipelines

All three live in `.github/workflows/`.

| Pipeline | When it runs | dev | prod |
|---|---|---|---|
| **vm-deploy** | Pull request to `main` | plan, posted as a PR comment | plan, posted as a PR comment |
| **vm-deploy** | Push / merge to `main` (only if `infra/`, `modules/` or the workflow files changed) | plan → **apply automatically** | **plan only**, never applies |
| **vm-deploy** | Run by hand ("Run workflow") | plan or apply | plan, or apply **after approval** |
| **vm-destroy** | Run by hand only | destroy plan → destroy | destroy plan → **approval** → destroy |
| terraform-vm (reusable) | Never directly: the other two call it | – | – |

`vm-destroy` asks you to **type the environment name again** in the *confirm* box. If it does not
match, the run stops before doing anything.

Every run starts with two safety checks that fail fast with a clear message:
- **Check Azure variables**: the repo variables are set and the job is allowed to request a sign-in token.
- **Check Azure sign-in and state access**: signs in and reads the state container, printing the
  exact Azure error if something is wrong. It never prints any token.

---

## 5. Common tasks

Everything below is in the repo's **Actions** tab → choose the pipeline → **Run workflow**.

| I want to… | Do this |
|---|---|
| Recreate dev | Run **vm-deploy** with environment `dev`, action `apply`. (A push to `main` that changes `infra/` does it too.) |
| Deploy prod | Run **vm-deploy** with environment `prod`, action `apply`, then approve. |
| Preview a change | Run **vm-deploy** with action `plan`, or open a pull request and read the plan comment. |
| Change VM size, count, OS or IP ranges | Edit `infra/vm/env/<env>.tfvars`, open a PR, read the plan, merge. Merging applies dev only. |
| Delete an environment's VMs and network | Run **vm-destroy**, pick the environment, type its name in *confirm*. Approve if prod. |
| Approve a prod run | Open the run → **Review deployments** → tick `prod` → **Approve and deploy**. |
| Allow SSH from my IP | In the tfvars set `admin_source_cidrs = ["<your-ip>/32"]` and `create_public_ip = true`. Fine for dev; for prod prefer Azure Bastion. |
| Log in to a VM | `ssh azureadmin@<ip> -i ~/.ssh/id_ed25519` (needs the private key and network access). |
| Change the SSH key | Changing `ADMIN_SSH_PUBLIC_KEY` makes Terraform **rebuild** the VMs (Azure cannot swap the key in place this way). To keep a VM, add a key with `az vm user update … --ssh-key-value` instead. |

---

## 6. Current status

| | dev | prod |
|---|---|---|
| Layer A (foundation) | ✅ exists | ✅ exists |
| Layer B (VMs and network) | ❌ **destroyed** with `vm-destroy` (VM, disk and network: 7 resources) | ❌ network **destroyed** with `vm-destroy` (7 resources). The VMs were never created (quota). |
| Ready to deploy again | ✅ yes | ⚠️ waiting on Azure **quota** |

**Prod quota:** the prod subscription allows **0 vCPUs** of the `Standard DSv5` family in South
Central US, and prod needs 4 (two `Standard_D2s_v5`). After the quota request is approved
(Azure portal → Subscriptions → prod → **Usage + quotas** → *Standard DSv5 Family vCPUs* ≥ 4),
run **vm-deploy** with `prod` / `apply`. No code change is needed.

**Note:** the next push to `main` that changes `infra/`, `modules/` or the workflow files will
**recreate dev automatically**.

**Cost while destroyed:** only the two state storage accounts (a few cents a month). Managed
identities, role assignments and resource provider registrations are free.

---

## 7. Deleting everything, completely

`vm-destroy` only removes **layer B**. To remove **everything**, do it in this order. Layer B must go
first, because `vm-destroy` needs layer A to work.

**Step 1: remove the workload (layer B).** Run **vm-destroy** for `dev` and for `prod`.
Check: `az group show -n rg-app-dev-vm --subscription <dev-sub>` should say *not found*.

**Step 2: remove the Azure foundation (layer A).** In Azure Cloud Shell:

```bash
for env in dev prod; do
  [ $env = dev ] && sub=4db12431-b606-4b3d-a0bf-da48a2913526 || sub=184d2ede-e572-4d93-95bd-bfd15f8f9d24
  id=id-gh-murtalabello-github-azure-$env

  # Remove the identity's role on the subscription first. Deleting the identity alone would
  # leave an orphaned "Unknown" role assignment behind.
  pid=$(az identity show -g rg-tfstate-$env -n $id --subscription $sub --query principalId -o tsv)
  az role assignment delete --assignee "$pid" --scope /subscriptions/$sub --subscription $sub

  # Deletes the storage account (and the state files), the identity and its federated
  # credentials, and the Storage Blob Data Contributor role assignment with it.
  az group delete -n rg-tfstate-$env --subscription $sub --yes
done
```

**Step 3: remove the GitHub side.** In Cloud Shell, after `gh auth login`:

```bash
R=murtalabello/github-azure
for v in AZURE_TENANT_ID AZURE_CLIENT_ID_DEV AZURE_SUBSCRIPTION_ID_DEV \
         AZURE_CLIENT_ID_PROD AZURE_SUBSCRIPTION_ID_PROD ADMIN_SSH_PUBLIC_KEY; do
  gh variable delete $v -R $R
done
gh api -X DELETE repos/$R/environments/dev
gh api -X DELETE repos/$R/environments/prod
```

**Step 4 (optional): delete this repo's workflows** (`.github/workflows/`) so nothing tries to run.

Resource provider registrations can be left alone. They cost nothing.

---

## 8. Setting it up again from zero

Only needed if layer A was deleted, or for a new repo or subscription. Run from the repo root in
Azure Cloud Shell, signed in as an **Owner** of each subscription, with `gh auth login` done:

```bash
# 1. An SSH key for the VMs. Keep the private key (~/.ssh/id_ed25519) safe somewhere else too.
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# 2. Foundation for each environment. -S is the ID-based token subject (see section 2).
S='murtalabello@61387158/github-azure@1410712234'
./scripts/bootstrap-azure-oidc.sh -e dev  -s 4db12431-b606-4b3d-a0bf-da48a2913526 \
  -r murtalabello/github-azure -S "$S" -k ~/.ssh/id_ed25519.pub
./scripts/bootstrap-azure-oidc.sh -e prod -s 184d2ede-e572-4d93-95bd-bfd15f8f9d24 \
  -r murtalabello/github-azure -S "$S" -p murtalabello

# 3. The script rewrote infra/vm/env/*.backend.hcl with the new storage account names. Commit them.
git add infra/vm/env/*.backend.hcl && git commit -m "Point Terraform at the new state storage" && git push
```

What the script does, in order: creates `rg-tfstate-<env>` and the locked-down state storage →
creates the managed identity → adds the federated credentials → grants **Contributor** on the
subscription and **Storage Blob Data Contributor** on the storage → sets the GitHub variables →
creates the GitHub environment (prod gets you as required reviewer, `main` only) → writes the
backend file. It is safe to re-run: it skips whatever already exists.

Options: `-G` skips the GitHub part (it prints the values to set by hand); `-l <region>` changes
the region (default `southcentralus`). Leave out `-S` if your repo's tokens use the plain
`repo:<owner>/<repo>:…` format; the *Check Azure sign-in* step prints the format GitHub actually sends.

**Brand-new subscription?** Register the providers first, or the script and Terraform will fail:

```bash
for p in Microsoft.Storage Microsoft.ManagedIdentity Microsoft.Compute Microsoft.Network; do
  az provider register -n $p --subscription <sub-id>
done
```

---

## 9. Troubleshooting

| Error in the run | What it means | Fix |
|---|---|---|
| `AADSTS700213: No matching federated identity record` | The job's token subject is not in the identity's federated credentials. | Add a credential with the subject printed by the *Check Azure sign-in* step. |
| `No GitHub OIDC token available` | The job is not allowed to request a sign-in token. | The job needs `permissions: id-token: write` (already set in these workflows). |
| `… is empty — run scripts/bootstrap-azure-oidc.sh` | A repo variable is missing. | Set it in Settings → Variables (values in [section 3](#3-everything-stored-in-github)). |
| State container returned HTTP 403 | The identity cannot read the state storage. | Give it **Storage Blob Data Contributor** on the storage account. |
| `exceeding approved … Cores quota` | The subscription may not run that many vCPUs of that VM family in that region. | Request a quota increase, or choose a different `vm_size` in the tfvars. |
| `Saved plan is stale` | Something changed between plan and apply. | Run the pipeline again to make a fresh plan. |
| `Error acquiring the state lock` | Another run is using the state, or a run was cancelled mid-way. | Wait. If no run is active, break the lease on the state blob in the portal. |
| Prod job stuck on **Waiting** | It needs approval. | Open the run → **Review deployments** → approve `prod`. |
| Push to `main` started no run | Only changes under `infra/`, `modules/` or the two deploy workflow files trigger it. | Use **Run workflow** instead. |

---

## 10. Files in this repo

```
infra/vm/main.tf               ← layer B: resource group, network, firewall, and calls the VM module
infra/vm/variables.tf          ← every setting, with defaults
infra/vm/outputs.tf            ← what a run prints at the end (VM names and IPs)
infra/vm/versions.tf           ← Terraform/provider versions and the state backend type
infra/vm/env/dev.tfvars        ← dev settings: size, count, IP ranges, disk type
infra/vm/env/prod.tfvars       ← prod settings
infra/vm/env/dev.backend.hcl   ← where dev's state file lives (written by the bootstrap script)
infra/vm/env/prod.backend.hcl  ← where prod's state file lives
modules/vm/                    ← one VM: network interface, optional public IP, Linux or Windows VM
.github/workflows/vm-deploy.yml              ← deploy pipeline
.github/workflows/vm-destroy.yml             ← destroy pipeline
.github/workflows/terraform-vm-reusable.yml  ← shared steps: checks → plan → approval → apply
scripts/bootstrap-azure-oidc.sh              ← layer A setup (Azure CLI + GitHub CLI, not Terraform)
```
