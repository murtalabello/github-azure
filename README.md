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
| **A. Foundation** | Terraform state storage, the two identities GitHub signs in as (plan and apply), their permissions, GitHub settings | **Once, by hand**: `scripts/bootstrap-azure-oidc.sh` (Azure CLI + GitHub CLI). **Not Terraform.** | **No.** It must survive, because Terraform needs it to run at all. |
| **B. Workload** | The VMs and their network | **Terraform**, run by GitHub Actions | **Yes** |

Why is the foundation not in Terraform? Terraform needs somewhere to keep its state file and
some identity to sign in with *before* it can create anything. So those have to exist first.
This is the usual "chicken and egg" setup for Terraform.

### Layer A: the foundation (one-time setup, **not** Terraform)

Created once per environment, inside that environment's subscription.

| Resource | dev | prod | What it is for |
|---|---|---|---|
| Resource group | `rg-tfstate-dev` | `rg-tfstate-prod` | Holds everything below. Region: South Central US. |
| Storage account | `sttfstatedevb0e407` | `sttfstateprod9da4cd` | Stores the Terraform **state file** (Terraform's record of what it created). Locked down: no public access, no shared keys (sign-in only), TLS 1.2+, file versioning and 30-day soft delete so a bad change can be undone. |
| Blob container | `tfstate` | `tfstate` | The folder inside the storage account. State file: `vm/dev.tfstate` / `vm/prod.tfstate`. |
| **Apply identity** (user-assigned managed identity) | `id-gh-murtalabello-github-azure-dev` | `id-gh-murtalabello-github-azure-prod` | The Azure "user" that **apply and destroy** jobs sign in as. Can change things. Has no password. |
| ↳ Role: **Contributor** on the whole subscription | ✅ | ✅ | Create, change and delete resources (VMs, networks…) in its own subscription. |
| ↳ Role: **Storage Blob Data Contributor** on the storage account | ✅ | ✅ | Read and write the state file. |
| ↳ Federated credentials | `gh-env-dev-ids` | `gh-env-prod-ids` | Only jobs running **inside the GitHub environment** may sign in. See [section 2](#2-how-it-is-all-wired-together). |
| **Plan identity** (user-assigned managed identity) | `id-gh-murtalabello-github-azure-dev-plan` | `id-gh-murtalabello-github-azure-prod-plan` | The Azure "user" that **plan** jobs sign in as. **Read-only.** Has no password. |
| ↳ Role: **Reader** on the whole subscription | ✅ | ✅ | See resources, but not change them. |
| ↳ Role: **Storage Blob Data Reader** on the storage account | ✅ | ✅ | Read the state file, but not change it. |
| ↳ Federated credentials | `gh-branch-main-ids`, `gh-pull-request-ids` | same | Jobs running from `main`, and pull-request jobs, may sign in. |
| Resource providers registered | Compute, Network, Storage, ManagedIdentity (+ others Terraform registered on its first run) | same | A subscription must "switch on" a service before using it. One-time and free. |

The dev identities have **no** permissions in the prod subscription, and the prod identities have
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
 │ Microsoft Entra ID     │    "I want to act as identity <client ID>" (plan identity in a plan
 │                        │    job, apply identity in an apply/destroy job).
 │ (Azure sign-in)        │ 4. Entra checks the identity's federated credentials: is there a rule
 │                        │    whose subject matches what the token says? If not, sign-in fails
 └───────────┬────────────┘    (AADSTS700213). If yes, it hands back an Azure access token.
             │ 5. With that Azure token, Terraform:
             ▼
 ┌──────────────────────────────────────── that environment's subscription ──────────────┐
 │  plan job  (plan identity):  reads the state file and looks at what exists. Read-only.  │
 │  apply job (apply identity): writes the state file and creates/changes/deletes          │
 │                              rg-app-<env>-vm and everything in it.                      │
 └────────────────────────────────────────────────────────────────────────────────────────┘
```

Nothing in this chain is a stored secret. The GitHub token lasts minutes and only works for that
one job. The Azure token lasts about an hour.

### Which jobs are allowed to sign in (federated credentials)

GitHub puts a **subject** in every token that describes the job. Each identity has rules listing
the subjects it trusts. This repo's tokens use GitHub's **ID-based** subject format
(`murtalabello@61387158/github-azure@1410712234`, where the numbers are the owner and repo IDs).

| Identity | Credential name | Subject it trusts | Which jobs this lets in |
|---|---|---|---|
| **plan** (read-only) | `gh-branch-main-ids` | `repo:murtalabello@61387158/github-azure@1410712234:ref:refs/heads/main` | Plan jobs running from `main` (pushes and "Run workflow") |
| **plan** (read-only) | `gh-pull-request-ids` | `repo:murtalabello@61387158/github-azure@1410712234:pull_request` | Plan jobs on pull requests |
| **apply** (write) | `gh-env-dev-ids` / `gh-env-prod-ids` | `repo:murtalabello@61387158/github-azure@1410712234:environment:dev` (or `:prod`) | Apply and destroy jobs, which run **inside** the GitHub environment |

**What this protects.** The only identity that can change anything signs in **only** from a job
inside the `dev` or `prod` GitHub environment, and both environments only accept jobs from `main`:

- A **pull request** gets a read-only token. Even if someone edits a workflow file in a PR, it
  can look at Azure but cannot change anything, and cannot run in the `dev`/`prod` environments.
- A **push to `main`** can change dev (the normal pipeline does). Changing prod also needs
  **your approval** on the `prod` environment.
- Pull requests from **forks** get no Azure token at all (GitHub does not issue them one).

Remaining trust: anyone who can push to `main` can change dev without review. Protect `main` with a
branch rule (Settings → Branches → require a pull request and a review) to close that too.

### How the workflow passes the settings to Terraform

In `.github/workflows/terraform-vm-reusable.yml`, the repo variables become environment variables
that Terraform's Azure provider reads automatically:

| Terraform reads | Filled from | Means |
|---|---|---|
| `ARM_TENANT_ID` | `vars.AZURE_TENANT_ID` | Which Entra tenant to sign in to |
| `ARM_SUBSCRIPTION_ID` | `vars.AZURE_SUBSCRIPTION_ID_DEV` or `_PROD` | Which subscription to build in |
| `ARM_CLIENT_ID` (plan job) | `vars.AZURE_CLIENT_ID_PLAN_DEV` or `_PLAN_PROD` | Act as the **read-only** plan identity |
| `ARM_CLIENT_ID` (apply job) | `vars.AZURE_CLIENT_ID_DEV` or `_PROD` | Act as the **write** apply identity |
| `ARM_RESOURCE_PROVIDER_REGISTRATIONS=none` | fixed, plan job only | Don't try to register Azure services (a Reader isn't allowed to) |
| `ARM_USE_OIDC=true` | fixed | Sign in with the GitHub token (not a password) |
| `ARM_USE_AZUREAD=true` | fixed | Use sign-in (not storage keys) for the state file |
| `TF_VAR_admin_ssh_public_key` | `vars.ADMIN_SSH_PUBLIC_KEY` | The SSH public key put on the Linux VMs |

The environment chosen by the pipeline (dev or prod) decides which `_DEV` / `_PROD` values are
used. That is the **only** thing that points a run at one subscription or the other.

The state file location comes from `infra/vm/env/<env>.backend.hcl`, passed to `terraform init`.

### How plan → approval → apply works

1. **Plan job** signs in as the **read-only** plan identity, runs `terraform plan`, saves the plan
   file, and uploads it to the run as an artifact named `tfplan-vm-<env>` (kept for 1 day).
2. If the plan has **no changes**, the apply job is skipped.
3. **Apply job** runs inside the GitHub environment (`dev` or `prod`). For prod, GitHub pauses here
   until you approve.
4. Apply signs in as the **apply** identity, downloads **the exact plan file** from step 1 and applies it. So what you reviewed is
   exactly what happens. If something changed in the meantime, Terraform refuses the stale plan.
5. Only one job per environment at a time (GitHub `concurrency` group, shared by both pipelines).
   Apply also locks the state file while it works. Plan reads the state **without** locking it,
   because a read-only identity is not allowed to place the lock.

---

## 3. Everything stored in GitHub

### Repository variables (Settings → Secrets and variables → Actions → **Variables**)

These are **IDs, not secrets**. Knowing them does not let anyone sign in. Sign-in only works
from this repo's own workflow jobs, because of the federated credentials.

| Variable | Value | Used for |
|---|---|---|
| `AZURE_TENANT_ID` | `a0859c2c-6006-4f6c-8e7f-69a8fca8a849` | Both environments |
| `AZURE_SUBSCRIPTION_ID_DEV` | `4db12431-b606-4b3d-a0bf-da48a2913526` | dev subscription |
| `AZURE_CLIENT_ID_DEV` | `e53e62b3-39e3-403a-870c-a2fc8d05169d` | client ID of the dev **apply** identity `id-gh-murtalabello-github-azure-dev` |
| `AZURE_CLIENT_ID_PLAN_DEV` | `5b75fc9c-3bd3-45a1-9b92-8c7873e11ffc` | client ID of the dev **plan** identity `id-gh-murtalabello-github-azure-dev-plan` |
| `AZURE_SUBSCRIPTION_ID_PROD` | `184d2ede-e572-4d93-95bd-bfd15f8f9d24` | prod subscription |
| `AZURE_CLIENT_ID_PROD` | `3663ea7b-1640-4fb6-9a22-4ac9b4c8eb2a` | client ID of the prod **apply** identity `id-gh-murtalabello-github-azure-prod` |
| `AZURE_CLIENT_ID_PLAN_PROD` | `7398c098-2b70-4b57-9072-8484be08c9b9` | client ID of the prod **plan** identity `id-gh-murtalabello-github-azure-prod-plan` |
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
| `dev` | **Deployment branches: `main` only.** No approval: applies run straight away. | dev apply and destroy jobs |
| `prod` | **Deployment branches: `main` only.** **Required reviewer: `murtalabello`**: every prod apply/destroy waits for approval. | prod apply and destroy jobs |

"Deployment branches: `main` only" means a job from any other branch or a pull request is refused
before it starts, so it can never get the apply identity's token.

### Where the actual secrets are (outside GitHub)

| Secret | Where it is |
|---|---|
| SSH **private** key matching `ADMIN_SSH_PUBLIC_KEY` | Only where it was created (`~/.ssh/id_ed25519` in Azure Cloud Shell). It is not in GitHub or Azure. **If it is lost, nobody can SSH into the VMs.** Keep a copy somewhere safe. |
| Windows admin password (only if `os_type = "windows"`) | Generated by Terraform and kept in the **Terraform state file** (and in the plan artifact for up to 1 day). Read it with `terraform output -raw windows_admin_password`. |
| Terraform state file | `sttfstate…/tfstate/vm/<env>.tfstate`. Readable by that environment's two GitHub identities (only the apply identity can write it) and by subscription owners. |

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
| Layer A (foundation) | ❌ **deleted** in Azure. Rebuild with [section 8](#8-setting-it-up-again-from-zero). | ❌ **deleted** in Azure. Rebuild with [section 8](#8-setting-it-up-again-from-zero). |
| Layer B (VMs and network) | ❌ **destroyed** with `vm-destroy` (VM, disk and network: 7 resources). Recreate with `vm-deploy` dev / apply. | ❌ network **destroyed** with `vm-destroy` (7 resources). The VMs were never created (quota). |
| Ready to deploy again | After section 8 | After section 8, plus Azure **quota** |

Until layer A is rebuilt, every pipeline run fails at *Check Azure sign-in and state access*:
the identities and state storage the GitHub variables point at no longer exist.

**Prod quota:** the prod subscription allows **0 vCPUs** of the `Standard DSv5` family in South
Central US, and prod needs 4 (two `Standard_D2s_v5`). After the quota request is approved
(Azure portal → Subscriptions → prod → **Usage + quotas** → *Standard DSv5 Family vCPUs* ≥ 4),
run **vm-deploy** with `prod` / `apply`. No code change is needed.

**Note:** a push to `main` that changes `infra/`, `modules/` or the workflow files **applies dev
automatically**. Commits with `[skip ci]` in the message skip that.

**Cost right now:** nothing. Once rebuilt, the two state storage accounts cost a few cents a
month, and dev's `Standard_B2s` VM and disk are billed while dev is deployed.

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
  # Remove each identity's role on the subscription first (Contributor / Reader). Deleting an
  # identity alone would leave an orphaned "Unknown" role assignment behind.
  for id in id-gh-murtalabello-github-azure-$env id-gh-murtalabello-github-azure-$env-plan; do
    pid=$(az identity show -g rg-tfstate-$env -n $id --subscription $sub --query principalId -o tsv)
    az role assignment delete --assignee "$pid" --scope /subscriptions/$sub --subscription $sub
  done

  # Deletes the storage account (and the state files), both identities and their federated
  # credentials, and the storage role assignments with them.
  az group delete -n rg-tfstate-$env --subscription $sub --yes
done
```

**Step 3: remove the GitHub side.** In Cloud Shell, after `gh auth login`:

```bash
R=murtalabello/github-azure
for v in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID_DEV AZURE_CLIENT_ID_DEV AZURE_CLIENT_ID_PLAN_DEV \
         AZURE_SUBSCRIPTION_ID_PROD AZURE_CLIENT_ID_PROD AZURE_CLIENT_ID_PLAN_PROD ADMIN_SSH_PUBLIC_KEY; do
  gh variable delete $v -R $R
done
gh api -X DELETE repos/$R/environments/dev
gh api -X DELETE repos/$R/environments/prod
```

**Step 4 (optional): delete this repo's workflows** (`.github/workflows/`) so nothing tries to run.

Resource provider registrations can be left alone. They cost nothing.

---

## 8. Setting it up again from zero

Use this when layer A (the foundation) has been deleted, for example after
[section 7](#7-deleting-everything-completely), or for a new subscription or repo. Everything below
runs in **Azure Cloud Shell (Bash)**, signed in to Azure as an **Owner** of both subscriptions.
It takes about 10 minutes.

**What you end up with:** new state storage, new identities and new GitHub variables. The **storage
account names and client IDs will be different** from the ones in this README (the script prints
the new ones). Terraform starts with an **empty state**, so make sure no old `rg-app-<env>-vm`
resource groups are left over, or Terraform will fail when it tries to create them again.

### Step 1: tools and sign-in

```bash
gh auth status || gh auth login        # GitHub.com → HTTPS → Yes (authenticate Git) → web browser
gh auth setup-git                      # lets git push with the same login
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
az account show --query user.name -o tsv   # should show your Azure account
```

### Step 2: get the code

```bash
cd ~ && rm -rf github-azure
gh repo clone murtalabello/github-azure && cd github-azure
chmod +x scripts/bootstrap-azure-oidc.sh
```

### Step 3: an SSH key for the VMs

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

Cloud Shell can lose files when it restarts. **Copy `~/.ssh/id_ed25519` (the private key) somewhere
safe**, or you will not be able to log in to the VMs later.

### Step 4: switch on the Azure services (safe to repeat)

```bash
for sub in 4db12431-b606-4b3d-a0bf-da48a2913526 184d2ede-e572-4d93-95bd-bfd15f8f9d24; do
  for p in Microsoft.Storage Microsoft.ManagedIdentity Microsoft.Compute Microsoft.Network; do
    az provider register -n $p --subscription $sub
  done
done
```

### Step 5: build the foundation (layer A) for both environments

```bash
S='murtalabello@61387158/github-azure@1410712234'   # this repo's ID-based token subject
./scripts/bootstrap-azure-oidc.sh -e dev  -s 4db12431-b606-4b3d-a0bf-da48a2913526 \
  -r murtalabello/github-azure -S "$S" -k ~/.ssh/id_ed25519.pub
./scripts/bootstrap-azure-oidc.sh -e prod -s 184d2ede-e572-4d93-95bd-bfd15f8f9d24 \
  -r murtalabello/github-azure -S "$S" -p murtalabello
```

Each run ends with `==> Done: <env>` and a summary of the tenant, subscription, both identities
and the storage account. What it does, in order:

1. creates `rg-tfstate-<env>` and the locked-down state storage account + `tfstate` container
2. creates the **apply** identity: environment sign-in only, **Contributor** + **Storage Blob Data Contributor**
3. creates the **plan** identity: `main` and pull-request sign-in, **Reader** + **Storage Blob Data Reader**
4. sets the GitHub variables (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID_<ENV>`,
   `AZURE_CLIENT_ID_<ENV>`, `AZURE_CLIENT_ID_PLAN_<ENV>`, and `ADMIN_SSH_PUBLIC_KEY` from `-k`)
5. creates the GitHub environment, deployable from `main` only (prod also gets you as required reviewer)
6. rewrites `infra/vm/env/<env>.backend.hcl` with the new storage account name

It is safe to re-run: it skips anything that already exists. If a role assignment step retries
a few times, that is normal (a new identity takes a moment to appear).

### Step 6: save the new state locations to the repo

```bash
git add infra/vm/env/*.backend.hcl
git commit -m "Point Terraform at the new state storage [skip ci]"
git push origin main
```

`[skip ci]` stops this push from deploying dev straight away. Leave it out if you want dev deployed
immediately.

### Step 7: check, then deploy

In GitHub → **Actions**:

1. **vm-deploy** → Run workflow → `dev` / `plan`. The *Check Azure sign-in and state access* step
   must pass, and the plan should say **7 to add**.
2. Same for `prod` / `plan`: **9 to add**.
3. Deploy: `dev` / `apply` (runs straight away), and `prod` / `apply` (approve when asked; needs
   the DSv5 quota, see [section 6](#6-current-status)).

### Optional tidy-up

- **Leftover role assignments.** If the old identities were deleted without removing their roles
  first, each subscription keeps role assignments for identities that no longer exist. They are
  harmless. To remove them in the portal: Subscription → **Access control (IAM)** → **Role
  assignments**; they show as *Identity not found*. Select them and **Remove**.
- **This README's tables** (sections 1 and 3) list the old storage account names and client IDs.
  Update them with the values the script printed.

**Options of the script:** `-G` skips the GitHub part (it prints the values to set by hand);
`-l <region>` changes the region (default `southcentralus`). Leave out `-S` if your repo's tokens
use the plain `repo:<owner>/<repo>:…` format; the *Check Azure sign-in* step prints the format
GitHub actually sends.

---

## 9. Troubleshooting

| Error in the run | What it means | Fix |
|---|---|---|
| `AADSTS700213: No matching federated identity record` | The job's token subject is not in the identity's federated credentials. | Add a credential with the subject printed by the *Check Azure sign-in* step. |
| `No GitHub OIDC token available` | The job is not allowed to request a sign-in token. | The job needs `permissions: id-token: write` (already set in these workflows). |
| `ARM_… is empty — set the AZURE_* repo variables for <env>` | A repo variable is missing. | Set it in Settings → Variables (values in [section 3](#3-everything-stored-in-github)). |
| State container returned HTTP 403 | The identity cannot read the state storage. | Plan identity needs **Storage Blob Data Reader**, apply identity needs **Storage Blob Data Contributor**, on the storage account. |
| `AuthorizationFailed … does not have authorization to perform action '…/write'` in a **plan** job | Something tried to change Azure with the read-only identity. | Expected protection. Only apply jobs may change things. |
| `Deployment … not allowed … branch protection rules` / job rejected by environment | A job from a branch other than `main` tried to use the `dev`/`prod` environment. | Expected protection. Merge to `main` first. |
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
