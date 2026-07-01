# Faceswap — Ansible setup & deploy

Replaces the legacy bash scripts (`setup-vast.sh`, `create-cloudcopy-key.sh`,
`docker-faceswap.sh`, `convert-faces.sh`) with Ansible playbooks built from
**built-in + community modules** (`git`, `pip`, `cron`, `uri`, `template`,
`replace`, `assert`, `community.docker.*`).

Run everything from this `ansible/` directory.

```bash
ansible-galaxy collection install -r requirements.yml   # one-time
```

## Inventory

- `cloud` → the vast.ai GPU instance. `ansible_host=vast-training` is a
  `~/.ssh/config` Host alias (host/port/key live in ssh config).
- `local` → this control machine (Docker extract/convert).

Config defaults live in `group_vars/` (`all.yml`, `cloud.yml`, `local.yml`).
Override anything at run time with `-e key=value`.

## Vault variables

Encrypted in `group_vars/vault.yml` (AES256). Edit with `ansible-vault edit group_vars/vault.yml`.

| Variable | Description |
|---|---|
| `vast_admin_key` | Vast.ai admin/primary API key — used by `cloud-provision-instance.yml` (create instances) |
| `runpod_api_key` | RunPod API key for submitting serverless jobs |
| `r2_access_key_id` | Cloudflare R2 access key — used by rclone on the training instance and control machine |
| `r2_secret_access_key` | Cloudflare R2 secret key |
| `r2_endpoint` | Cloudflare R2 endpoint URL (`https://<account>.r2.cloudflarestorage.com`) |

> `vast_api_key` — **removed**. Previously used for vast Cloud Copy; renamed to `vast_admin_key`.

## group_vars/cloud.yml — key variables

| Variable | Description |
|---|---|
| `fs_workspace_name` | Training session name — namespaces all R2 paths (pass with `-e`) |
| `cc_sync_src` | Local dir to push to R2 (default: `/workspace/train`) |
| `cc_interval_min` | R2 sync interval in minutes (default: `10`) |
| `r2_bucket` | Cloudflare R2 bucket (default: `faceswap-storage`) |
| `r2_faces_a_src` | R2 path for side-A faces (default: `<workspace>/extract/A`) |
| `r2_faces_b_src` | R2 path for side-B faces (default: `<workspace>/extract/B`) |
| `rp_endpoint_id` | RunPod endpoint ID (created once in RunPod console) |

## Cloud (vast.ai) — setup & train

| Task | Command |
|------|---------|
| Provision + setup instance | `ansible-playbook playbooks/cloud-provision-and-setup.yml` |
| Install deps + GPU check only | `ansible-playbook playbooks/cloud-install-faceswap.yml` |
| Validate faces/disk/GPU before train | `ansible-playbook playbooks/cloud-preflight.yml` |
| Start training (tmux) | `ansible-playbook playbooks/cloud-start-training.yml` |
| TensorBoard (tmux, port 6006) | `ansible-playbook playbooks/cloud-start-tensorboard.yml` |
| Pull extracted faces from R2 to instance | `ansible-playbook playbooks/cloud-pull-train-faces.yml -e fs_workspace_name=alice-bob-001` |
| Auto R2 sync cron (rclone push model) | `ansible-playbook playbooks/cloud-install-sync-cron.yml -e fs_workspace_name=alice-bob-001` |

Training params: `-e fs_trainer=original -e fs_batch_size=16` (see `group_vars/cloud.yml`).

## Vast.ai — instance management

```bash
# Provision VastAI instance via Terraform (writes rp_endpoint_id back to cloud.yml)
ansible-playbook playbooks/cloud-provision-instance.yml

# Destroy instance
ansible-playbook playbooks/cloud-provision-instance.yml -e destroy=true
```

## RunPod Serverless extract

| Task | Command |
|------|---------|
| Health-check endpoint | `ansible-playbook playbooks/cloud-serverless-deploy.yml` |
| Submit extract job (R2 source → R2 extract) | `ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=alice.mp4 -e sl_side=A` |

R2 credentials (`RCLONE_CONFIG_R2_*`, `R2_BUCKET`) are injected via Terraform as RunPod template env vars (see `terraform/runpod_template.tf`).

## Local — extract / convert (Docker, Intel-Mac)

| Task | Command |
|------|---------|
| Build CPU image (once) | `ansible-playbook playbooks/local-build.yml` |
| Extract → dedupe → sharpness (review folder) | `ansible-playbook playbooks/local-extract.yml -e fs_input=alice.mp4 -e fs_ws=alice` |
| Standalone dedupe | `ansible-playbook playbooks/local-dedupe.yml -e fs_faces_out=workspace/alice/faces` |
| Standalone sharpness report/filter | `ansible-playbook playbooks/local-sharp.yml -e fs_faces_out=workspace/alice/faces -e fs_blur_threshold=100` |
| Convert (face swap) | `ansible-playbook playbooks/local-convert.yml -e fs_ws=alice` |

Apple Silicon / Linux with native torch: add `-e fs_local_backend=native`
(skips Docker, runs `faceswap.py` directly).

## End-to-end flow

```
(set R2 creds in vault.yml + terraform) →
  runpod-extract-faces (A + B) → curate extracted faces in R2 →
  cloud-provision-instance → cloud-install-faceswap →
  cloud-pull-train-faces (R2 → instance) →
  cloud-preflight → cloud-start-training →
  cloud-install-sync-cron (cron: rclone push model → R2) →
  (done, cloud-provision-instance -e destroy=true)
```

## Removed

- `provision-vast-instance.yml` — replaced by `cloud-provision-instance.yml`.
- `provision-key.yml` + `vast_cloudcopy_key` role — vastai cloud copy replaced by rclone.
- `vast_deploy_key` role — no longer needed.
- `vast_api_key` vault variable — renamed to `vast_admin_key`.
- `cloud-pull-train-faces.yml` — **re-added**; pulls faces from R2 (RunPod extract output) to the training instance.
- `vault-store-runpod-gdrive-oauth.yml` — removed; RunPod worker uses Cloudflare R2, not GDrive.
