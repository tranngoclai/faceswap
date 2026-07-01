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
| `vast_admin_key` | Vast.ai admin/primary API key — used by `terraform-gpu.yml` (create instances) |
| `runpod_api_key` | RunPod API key for submitting serverless jobs |

Google Drive service account JSON is stored separately in `group_vars/google-account-vault.yml`
(also AES256-encrypted). Manage with `ansible-playbook playbooks/provision-gdrive-sa-key.yml`.

| Variable | Description |
|---|---|
| `gdrive_sa_json` | Google SA JSON (full key file contents), AES256 encrypted |

> `vast_api_key` — **removed**. Previously used for vast Cloud Copy; replaced by rclone + gdrive service account.

## group_vars/cloud.yml — key variables

| Variable | Description |
|---|---|
| `fs_workspace_name` | Unique workspace name; reusing overwrites prior artifacts |
| `gdrive_root_folder_id` | Shared Drive folder ID — **required**, set by operator after sharing folder with SA email |
| `gdrive_train_model` | Drive destination for model artifacts (derived from workspace + train/model) |
| `cc_sync_src` | Local VastAI dir to push (default: `fs_train_model_dir` = `/workspace/train/model`) |
| `cc_sync_dst` | Drive destination for sync (derived: `gdrive_train_model`) |
| `cc_instance_id` | Updated automatically by `terraform-gpu.yml` — do not edit manually |
| `rp_endpoint_id` | RunPod endpoint ID (created once in RunPod console) |

## Cloud (vast.ai) — setup & train

| Task | Command |
|------|---------|
| Provision + setup instance | `ansible-playbook playbooks/cloud-provision-and-setup.yml` |
| Install deps + GPU check only | `ansible-playbook playbooks/cloud-setup.yml` |
| Sync Drive train inputs → VastAI | `ansible-playbook playbooks/cloud-sync-train-inputs.yml` |
| Validate faces/disk/GPU before train | `ansible-playbook playbooks/cloud-train-preflight.yml` |
| Start training (tmux) | `ansible-playbook playbooks/cloud-train.yml` |
| TensorBoard (tmux, port 6006) | `ansible-playbook playbooks/cloud-board.yml` |
| Auto cloud-sync cron → Drive | `ansible-playbook playbooks/cloud-cloudsync.yml` |
| rclone push/pull model | `ansible-playbook playbooks/cloud-rclone.yml -e rclone_direction=push -e rclone_remote=gdrive:faceswap-model` |

Training params: `-e fs_trainer=original -e fs_batch_size=16` (see `group_vars/cloud.yml`).

## Vast.ai — instance management

```bash
# Provision VastAI instance via Terraform (writes cc_instance_id back to cloud.yml)
ansible-playbook playbooks/terraform-gpu.yml

# Destroy instance
ansible-playbook playbooks/terraform-gpu.yml -e destroy=true
```

## RunPod Serverless extract

| Task | Command |
|------|---------|
| Health-check endpoint | `ansible-playbook playbooks/cloud-serverless-deploy.yml` |
| Submit extract job (Drive source → Drive extract) | `ansible-playbook playbooks/cloud-serverless-extract.yml -e sl_input=alice.mp4 -e sl_side=A` |

Endpoint secrets set in RunPod console (not stored here):
`GDRIVE_SA_JSON_B64`, `GDRIVE_ROOT_FOLDER_ID`.

## Google Drive / rclone setup

```bash
# Encrypt and store new SA key (prompts for JSON path)
ansible-playbook playbooks/provision-gdrive-sa-key.yml

# Install on-instance rclone + cron (syncs model back to Drive every 10 min)
ansible-playbook playbooks/cloud-cloudsync.yml

# Provision cloudsync key permissions
ansible-playbook playbooks/provision-cloudsync-key.yml
```

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

## End-to-end (Drive-first flow)

```
provision-gdrive-sa-key → (set RunPod endpoint secrets) →
  cloud-serverless-extract (A + B) → curate in Drive →
  terraform-gpu → cloud-setup →
  cloud-sync-train-inputs → cloud-train-preflight →
  cloud-train → cloud-cloudsync (cron) → (done, terraform-gpu -e destroy=true)
```

## Removed

- `provision-vast-instance.yml` — replaced by `terraform-gpu.yml`.
- `provision-key.yml` + `vast_cloudcopy_key` role — vastai cloud copy replaced by rclone + gdrive.
- `vast_deploy_key` role — replaced by gdrive service account auth.
- `vast_api_key` vault variable — renamed to `vast_admin_key`.
- R2/Cloudflare storage — replaced by Google Drive throughout.
