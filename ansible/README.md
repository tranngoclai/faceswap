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
- `local` → this control machine (Docker extract/convert + key minting).

Config defaults live in `group_vars/` (`all.yml`, `cloud.yml`, `local.yml`).
Override anything at run time with `-e key=value`.

## Cloud (vast.ai) — setup & train

| Task | Command |
|------|---------|
| Install (clone + deps + preview patch) + GPU check | `ansible-playbook playbooks/cloud-setup.yml` |
| Start training (tmux) | `ansible-playbook playbooks/cloud-train.yml` |
| TensorBoard (tmux, port 6006) | `ansible-playbook playbooks/cloud-board.yml` |
| Auto cloud-sync cron → Drive | `VAST_API_KEY=<scoped> ansible-playbook playbooks/cloud-cloudsync.yml` |
| rclone push/pull model | `ansible-playbook playbooks/cloud-rclone.yml -e rclone_direction=push -e rclone_remote=gdrive:faceswap-model` |

Training params: `-e fs_trainer=original -e fs_batch_size=16` (see `group_vars/cloud.yml`).

## Scoped vast API key (run before cloud-sync)

```bash
# Mint a minimal (cloud-copy only) key with your admin/primary key:
VAST_ADMIN_KEY=<primary> ansible-playbook playbooks/provision-key.yml
#   add -e set_account_env_var=true to also store it as a vast account env-var.
# Use the printed key as VAST_API_KEY for cloud-cloudsync.yml.
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

## End-to-end

```
provision-key → cloud-setup → cloud-train → cloud-cloudsync   (cloud)
local-build → local-extract → (curate) → local-convert        (local)
```
