# Drive-first Operator Flow Report

## Context

Repo hiện có 2 luồng đang song song:

- Luồng cũ: local extract -> VastAI train -> Google Drive sync.
- Luồng mới: app/RunPod serverless extract -> Cloudflare R2 -> chưa có handoff chuẩn sang VastAI train.

Spec đã chốt sẽ migrate hoàn toàn sang Google Drive làm source of truth. R2 không còn là contract chính.

## Confirmed Specs

- Storage source of truth: Google Drive.
- Google Drive root contract: shared folder ID, not path-only. Operator shares this folder with the Google service account.
- RunPod worker: đọc/ghi Google Drive trực tiếp.
- App upload: upload input video lên Google Drive using Ansible-injected Google service account credential.
- Drive layout: `train/faceswap/<workspace-name>/...`.
- Train trigger: Operator chạy Ansible thủ công.
- Curation: bắt buộc, Operator curate manual trên Google Drive.
- Secret policy: practical secure.
- Environment: một env.
- Google service account credential: chỉ lưu trong Ansible Vault at rest; app/local, RunPod, VastAI nhận credential khi Ansible setup/provision or secure endpoint secret setup.
- RunPod endpoint secret format: base64-encoded service account JSON; worker decodes to a temporary/service file with mode `0600`.
- RunPod submit behavior: every caller must poll `/status/{job_id}` until terminal state if `/runsync` returns `IN_PROGRESS`.
- Train artifacts: sync model artifacts from `/workspace/train/model` về Google Drive under the same workspace path.
- Workspace names must be unique enough; reusing `<workspace-name>` can overwrite previous `train/model` artifacts and train inputs.

## Target Flow

```text
Operator encrypt Google SA JSON into Ansible Vault
Operator shares Drive root folder with Google service account
Operator setup RunPod endpoint base64 SA secret from Vault/manual secure step
Ansible injects Google SA credential for local app runtime
App uploads source video to Google Drive
RunPod extracts from Drive and writes faces to Drive
Operator manually curates faces in Drive
Operator provisions VastAI instance with Ansible
Ansible syncs approved train inputs from Drive to VastAI /workspace/train
Operator starts training with Ansible
Ansible syncs /workspace/train/model back to Drive
Operator cleans up or stops VastAI instance
```

## Re-evaluated Google Drive Layout

Decision: the configured `gdrive_root_folder_id` should point directly at the shared canonical `train/faceswap` folder. Human-facing docs can still display `train/faceswap/<workspace-name>/...`, but automation should treat paths below as relative to that folder ID and use `gdrive:` as the remote root.

Reason: this avoids path-by-name lookup for `train` and `faceswap`, avoids duplicate-folder collisions, and gives app, RunPod, VastAI, and operator runbooks one contract.

```text
<workspace-name>/
├── source/
│   ├── A/                         # original media/frames for side A
│   └── B/                         # original media/frames for side B
├── extract/
│   ├── A/                          # latest candidate faces for side A; overwrite allowed
│   └── B/                          # latest candidate faces for side B; overwrite allowed
├── train/                          # canonical train data + artifacts
│   ├── input_A/                    # operator-approved side A; syncs to /workspace/train/input_aligned
│   ├── input_B/                    # operator-approved side B; syncs to /workspace/train/output/faces_full
│   └── model/                      # model artifacts synced back from VastAI
├── logs/                           # app/runpod/ansible/train logs when available
└── manifest.json
```

Displayed full Drive path remains:

```text
train/faceswap/<workspace-name>/...
```

But with `gdrive_root_folder_id` set to the shared `train/faceswap` folder, automation paths should be:

```text
gdrive:<workspace-name>/source/A
gdrive:<workspace-name>/extract/A
gdrive:<workspace-name>/train/input_A
gdrive:<workspace-name>/train/input_B
gdrive:<workspace-name>/train/model
```

Avoid `gdrive:train/faceswap/<workspace-name>` in automation unless `gdrive_root_folder_id` intentionally points to a higher-level shared folder. Mixing these two conventions will create duplicate trees.

### Layout Assessment Across Flows

- App upload should write original video/frame input to `source/<side>/`, not `uploads/<job-id>` or R2 paths. The app must require `fs_workspace_name` and side `A|B`, then create a stable source object path such as `source/A/<filename>`.
- RunPod extract should read from `source/<side>/` and write candidate faces to flat `extract/<side>/`. Re-running extract for the same workspace/side may overwrite previous candidates by design.
- Manual curation should copy approved side A faces directly into `train/input_A/` and side B faces directly into `train/input_B/`. Do not keep a separate `curated/` tree because it duplicates storage.
- VastAI sync-in should copy `train/input_A/` to `/workspace/train/input_aligned/` and `train/input_B/` to `/workspace/train/output/faces_full/`.
- VastAI sync-out should copy `/workspace/train/model/` back to `train/model/`. If full train sync is needed, sync `/workspace/train/` to `train/`, but do not overwrite curated training inputs unless explicitly requested.
- Local extract, if kept, should either upload its reviewed candidates to `extract/<side>/` or, after operator approval, directly to `train/input_A/` or `train/input_B/`. It should not keep a separate canonical local-only `workspace/<ws>/faces` contract for the Drive-first flow.
- Convert/model pull should read model artifacts from `train/model/` for the selected workspace.

## Training Path Mapping

- Drive `train/faceswap/<workspace-name>/train/input_A/` -> VastAI `/workspace/train/input_aligned/`
- Drive `train/faceswap/<workspace-name>/train/input_B/` -> VastAI `/workspace/train/output/faces_full/`
- VastAI `/workspace/train/model/` -> Drive `train/faceswap/<workspace-name>/train/model/`
- Mapping is resolved under the configured shared folder ID/root. Display paths are human-readable; automation should use the configured root folder ID where possible.

## Current Repo Findings

- `app/main.py` currently uploads to Cloudflare R2 and calls RunPod `/runsync`.
- `scripts/cloud/serverless_extract.py` currently uses `rclone copy` with R2 remote.
- `docker/serverless/Dockerfile` packages the RunPod worker and rclone.
- `ansible/playbooks/cloud-serverless-deploy.yml` only health-checks RunPod endpoint; it does not deploy endpoint config.
- `ansible/playbooks/runpod-extract-faces.yml` submits RunPod extract job using R2 paths.
- `ansible/playbooks/vault-store-gdrive-sa-key.yml` encrypts Google service account JSON into `google-account-vault.yml`.
- `ansible/roles/faceswap_cloudsync` already configures rclone Google Drive remote on VastAI from Vault.
- `ansible/playbooks/provision-vast-instance.yml` provisions VastAI and patches `~/.ssh/config`.
- `ansible/roles/faceswap_train` starts training in tmux and expects local VastAI folders to exist.

## Security Assessment

Practical secure baseline:

- Keep Google service account JSON only in Ansible Vault at rest.
- Do not commit plaintext secrets or `.env` files.
- Do not print decrypted Vault content in logs.
- Use admin/primary VastAI key only for local provisioning/key-minting.
- Use scoped VastAI runtime key for cloud-copy or runtime tasks where possible.
- Put Google service account file on cloud runtime only during setup/use, mode `0600`.
- RunPod API key stored in `ansible/group_vars/vault.yml` (encrypted), managed via `vault-store-runpod-key.yml` playbook; keep separate from app/endpoint secrets.
- Use one env only, but keep names explicit to avoid accidental cross-run overwrite.

Known risks to address:

- `ansible/group_vars/cloud.yml` currently hardcodes `rp_endpoint_id`.
- `ansible/group_vars/vault.yml` is tracked; acceptable only if encrypted with Ansible Vault.
- `ansible/group_vars/google-account-vault.yml` is untracked in current worktree; commit only if encrypted and intended.
- `provision-vast-instance.yml` appears to update `cc_instance_id`, but `cloud.yml` currently has no such var.
- `provision-vast-instance.yml` uses `vast_api_key`; confirm this key has create-instance permission or switch provisioning to `vast_admin_key`.
- `ansible.cfg` disables host key checking. This is convenient for ephemeral VastAI but should be documented as a trade-off.
- App upload now depends on Ansible-provisioned local credential path/env. Gradio itself does not manage this; the Python app must read the injected credential path or use an injected rclone config.
- Google Drive path-by-name can collide. Shared folder ID/root folder ID must be the real contract; `manifest.json` should record folder IDs after creation.
- RunPod base64 secret can leak if printed. Worker setup must avoid logging decoded content and should write the decoded JSON with `0600` permissions.
- Periodic/final sync of `/workspace/train/model` can overwrite prior model artifacts if `fs_workspace_name` is reused.
- Existing serverless CLI submit path may need status polling parity with `app/main.py`; otherwise long jobs can return `IN_PROGRESS` and be treated as done.

## Required Repo Changes

1. Replace R2 contract in `app/main.py` with Google Drive upload/list/preview using Ansible-injected SA credential or injected rclone config.
2. Replace R2 contract in `scripts/cloud/serverless_extract.py` with Google Drive rclone remote rooted at the shared folder ID.
3. Add or update RunPod endpoint secret setup docs/playbook so worker receives base64 SA JSON securely and decodes it to a `0600` file.
4. Add Drive path config to `ansible/group_vars/cloud.yml`, centered on `fs_workspace_name` and shared folder ID/root folder ID.
5. Add playbook to sync Drive train input folders to VastAI training dirs.
6. Add preflight train validation: train input A/B exists, face count sufficient, images readable, Drive read/write works, disk OK, GPU OK, no conflicting training session.
7. Update `docs/cloud-training-vast.md` and `ansible/README.md` to make Drive-first flow canonical.
8. **✓ RESOLVED:** VastAI provisioning now via Terraform (cloud-provision-instance.yml) with proper key semantics; `cc_instance_id`/`rp_pod_id` auto-managed and stored in cloud.yml.
9. Make all RunPod submit callers poll `/status/{job_id}` to terminal state when `/runsync` returns `IN_PROGRESS`.
10. Define `manifest.json` enough to record workspace name, root folder ID, folder IDs, source files, extract outputs, and schema version.

## Recommended Ansible Variables

```yaml
fs_workspace_name: alice-bob-001
gdrive_remote_name: gdrive
gdrive_root_folder_id: "<shared-folder-id>"
gdrive_root: "{{ gdrive_remote_name }}:"
gdrive_workspace: "{{ gdrive_root }}/{{ fs_workspace_name }}"
gdrive_source_a: "{{ gdrive_workspace }}/source/A"
gdrive_source_b: "{{ gdrive_workspace }}/source/B"
gdrive_extract_a: "{{ gdrive_workspace }}/extract/A"
gdrive_extract_b: "{{ gdrive_workspace }}/extract/B"
gdrive_train_root: "{{ gdrive_workspace }}/train"
gdrive_train_input_a: "{{ gdrive_train_root }}/input_A"
gdrive_train_input_b: "{{ gdrive_train_root }}/input_B"
gdrive_train_model: "{{ gdrive_train_root }}/model"
fs_faces_a: /workspace/train/input_aligned
fs_faces_b: /workspace/train/output/faces_full
fs_train_model_dir: /workspace/train/model
gdrive_sa_json_b64_env: GDRIVE_SA_JSON_B64
gdrive_sa_file: /root/.config/gdrive/service-account.json
```

This report recommends that `gdrive_root_folder_id` points directly at the shared `train/faceswap` root. If a higher-level folder is used instead, change `gdrive_root` to `{{ gdrive_remote_name }}:train/faceswap` everywhere in one migration; do not mix conventions.

## Operator Runbook

1. Encrypt or rotate Google service account key:
   `ansible-playbook playbooks/vault-store-gdrive-sa-key.yml -e gdrive_sa_key_file=/path/to/service-account.json`

2. Create or choose the Google Drive root folder and share it with the service account email. Record its folder ID in Ansible vars.

3. Configure local app credential via Ansible so the Gradio/Python app can upload using the service account credential path or rclone config.

4. Configure RunPod endpoint secret `GDRIVE_SA_JSON_B64` from the vaulted service account JSON. Worker decodes it to a credential file with mode `0600`.

5. Start app and upload source videos to:
   `train/faceswap/<workspace-name>/source/A/` and `train/faceswap/<workspace-name>/source/B/`

6. Run RunPod extract for A and B. Submitter polls until terminal status. Output goes to flat folders and may overwrite previous extract candidates for the same workspace/side:
   `train/faceswap/<workspace-name>/extract/A/` and `train/faceswap/<workspace-name>/extract/B/`

7. Operator manually curates in Google Drive by copying approved faces directly to the train input folders:
   `train/faceswap/<workspace-name>/train/input_A/` and `train/faceswap/<workspace-name>/train/input_B/`

8. Provision and setup VastAI (via Terraform):
   `ansible-playbook playbooks/cloud-provision-instance.yml`
   `ansible-playbook playbooks/cloud-install-faceswap.yml`

9. Sync Drive train input folders to VastAI training dirs:
   `ansible-playbook playbooks/cloud-pull-train-faces.yml -e fs_workspace_name=<workspace-name>`

10. Run train preflight:
    `ansible-playbook playbooks/cloud-preflight.yml -e fs_workspace_name=<workspace-name>`

11. Start training:
    `ansible-playbook playbooks/cloud-start-training.yml -e fs_workspace_name=<workspace-name>`

12. Sync model artifacts back to Google Drive:
     `ansible-playbook playbooks/cloud-install-sync-cron.yml -e fs_workspace_name=<workspace-name>`

13. Stop or destroy VastAI instance when done.

## Acceptance Criteria

- App no longer requires R2 credentials for the canonical flow.
- App can upload to Google Drive with credential/config injected by Ansible.
- Drive automation uses a configured shared folder ID/root folder ID, not path-only discovery.
- RunPod worker can extract using Google Drive source and output paths.
- RunPod worker receives base64 SA JSON secret, decodes it without logging secret content, and writes credential file mode `0600`.
- RunPod submit callers poll to `COMPLETED`/`FAILED`/terminal state when jobs outlive `/runsync`.
- Operator cannot start training until train input folders exist and pass preflight.
- VastAI training reads from `/workspace/train/input_aligned` and `/workspace/train/output/faces_full`.
- Model artifacts sync to `train/faceswap/<workspace-name>/train/model`.
- No plaintext Google service account JSON, RunPod key, or VastAI key is committed or printed.

## Unresolved Questions

- Exact `manifest.json` schema is not defined yet, but it should include schema version, workspace name, root folder ID, folder IDs, source files, and extract output references.
- Whether RunPod endpoint secrets should be set manually in console or automated via API remains undecided.
- Whether app Drive operations should call Google Drive API directly or shell out to `rclone` remains undecided. `rclone` is preferred for consistency unless app UX needs Drive API features.
