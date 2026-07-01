# Cloud Training trên vast.ai — Quy trình tổng hợp

Train faceswap trên GPU thuê tại [vast.ai](https://cloud.vast.ai).

> **⚙️ Đã chuyển toàn bộ setup/deploy sang Ansible** (`ansible/`). Chi tiết: [`ansible/README.md`](../ansible/README.md).

| Việc | Lệnh Ansible (chạy trong `ansible/`) |
|------|--------------------------------------|
| Cloud: provision VastAI instance (Terraform) | `ansible-playbook playbooks/terraform-manage-instance.yml` |
| Cloud: install + GPU check | `ansible-playbook playbooks/cloud-install-faceswap.yml` |
| Cloud: preflight check | `ansible-playbook playbooks/cloud-preflight.yml` |
| Cloud: train (tmux) | `ansible-playbook playbooks/cloud-start-training.yml` |
| Cloud: TensorBoard | `ansible-playbook playbooks/cloud-start-tensorboard.yml` |
| Cloud: auto cloud-sync cron | `ansible-playbook playbooks/cloud-install-sync-cron.yml` |
| Cloud: pull faces từ R2 → instance | `ansible-playbook playbooks/cloud-pull-train-faces.yml` |
| RunPod: serverless extract | `ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=alice.mp4 -e sl_side=A` |
| Add/edit vault secret | `ansible-playbook playbooks/vault-store-key.yml -e vault_key=x -e vault_value=y` |

> **Backend:** PyTorch + Keras 3 (KHÔNG còn TensorFlow). Train cần **NVIDIA GPU + CUDA**.

```
[App] upload video ───────────────────────────> [R2] <workspace>/source/A|B/
[RunPod Serverless] extract <── R2 input ──  faces ──> R2 extract/A|B/  (operator review)
[LOCAL] curate: copy approved faces → R2 <workspace>/train/input_A|B/
[VAST.AI] train ──> model/ ──sync back (cron: rclone copy → R2)──> R2 <workspace>/train/
```

---

## Quy trình operator hoàn chỉnh (R2-first)

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml          # 1 lần duy nhất

# 1. Đặt R2 credentials làm RunPod endpoint secrets (console):
#    RCLONE_CONFIG_R2_TYPE=s3, RCLONE_CONFIG_R2_PROVIDER=Cloudflare
#    RCLONE_CONFIG_R2_ACCESS_KEY_ID, RCLONE_CONFIG_R2_SECRET_ACCESS_KEY
#    RCLONE_CONFIG_R2_ENDPOINT, R2_BUCKET

# 2. Upload video nguồn lên R2 <workspace>/source/A|B/ (rclone copy hoặc App)

# 3. RunPod extract A + B (đợi tới khi job terminal)
ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=alice.mp4 -e sl_side=A
ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=bob.mp4   -e sl_side=B

# 4. Duyệt mặt trong R2 extract/A|B/
#    Copy approved faces → R2 <workspace>/train/input_A|B/

# 5. Provision VastAI instance (Terraform) + setup
ansible-playbook playbooks/terraform-manage-instance.yml
ansible-playbook playbooks/cloud-install-faceswap.yml

# 6. Pull faces từ R2 xuống instance
ansible-playbook playbooks/cloud-pull-train-faces.yml -e fs_workspace_name=alice-bob-001

# 7. Preflight: kiểm tra faces / disk / GPU trước khi train
ansible-playbook playbooks/cloud-preflight.yml

# 8. Train (tmux, chạy nền)
ansible-playbook playbooks/cloud-start-training.yml -e fs_trainer=original -e fs_batch_size=16
ansible-playbook playbooks/cloud-start-tensorboard.yml   # TensorBoard port 6006 (tuỳ chọn)

# 9. Cài cron auto-sync model → R2 (rclone copy) mỗi 10 phút
ansible-playbook playbooks/cloud-install-sync-cron.yml -e fs_workspace_name=alice-bob-001
#    -> /root/cloud-sync.sh; log: /root/cloud-sync.log

# 10. Xong → destroy instance
ansible-playbook playbooks/terraform-manage-instance.yml -e destroy=true
```

---

## 1. vast.ai: thuê instance + train

| Mục | Khuyến nghị |
|-----|-------------|
| **GPU** | RTX 3090 / 4090 / A5000 (24GB). Tối thiểu RTX 3060 12GB |
| **Image** | `vastai/base-image` CUDA **13.0** — **KHÔNG dùng `vastai/tensorflow`** (project chạy PyTorch, TF gây xung đột CUDA) |
| **Disk** | ≥ 40–60GB |
| **Ports** | 6006 (TensorBoard) |

**Khớp CUDA ↔ requirements** (đặt `faceswap_req_file` trong `group_vars/cloud.yml`):

| Image CUDA | `faceswap_req_file` |
|-----------|-----------|
| 12.6.x | `requirements/requirements_nvidia_12.txt` (cu126) |
| 12.8 / 13.0 | `requirements/requirements_nvidia_13.txt` (cu130) |

> Template **PyTorch sẵn** (`pytorch/pytorch:2.9-cuda12.8-cudnn9-runtime`)? Dùng `-e faceswap_skip_torch=true` giữ torch của image.

Tinh chỉnh train:
```bash
ansible-playbook playbooks/cloud-start-training.yml -e fs_trainer=villain -e fs_batch_size=8   # giảm batch nếu CUDA OOM
ansible-playbook playbooks/cloud-start-tensorboard.yml                                            # TensorBoard 0.0.0.0:6006
```

> **Preview nằm trong data dir:** `cloud-install-faceswap.yml` tự vá `scripts/train.py` để ghi `training_preview.png` vào **thư mục model** (`fs_train_model_dir`) thay vì cạnh `faceswap.py` → preview + model đều nằm dưới `/workspace` → cloud-sync cron hoạt động được.

---

## 2. Auto-sync model (rclone → R2)

`cloud-install-sync-cron.yml` cài **cron mỗi 10 phút** chạy `rclone copy` đẩy `/workspace/train` → Cloudflare R2 `<fs_workspace_name>/train/`. R2 credentials inject qua crontab env lines (từ vault) — không cần rclone.conf trên disk.

```bash
ansible-playbook playbooks/cloud-install-sync-cron.yml -e fs_workspace_name=alice-bob-001
#   -> /root/cloud-sync.sh; crontab */10; log: /root/cloud-sync.log
```

> Gỡ cron khi xong: `ssh vast-training "crontab -r"`.

---

## 3. Serverless extract — RunPod + Cloudflare R2

Extract faces theo **job, scale-to-zero** trên [RunPod Serverless](https://runpod.io). Worker kéo video input từ **Cloudflare R2**, extract trên GPU, đẩy faces ngược lại R2 qua `rclone copy`.

### Layout R2

```
<fs_workspace_name>/        (bucket: faceswap-storage)
├── source/A/        # video nguồn upload lên
├── source/B/
├── extract/A/       # RunPod extract output — operator review tại đây
├── extract/B/
└── train/           # model sync từ VastAI
    ├── input_A/
    ├── input_B/
    └── model/
```

### Setup 1 lần

1. Tạo serverless endpoint trong **RunPod console** (image: `ghcr.io/tranngoclai/faceswap-sl:<tag>`) → ghi lại `RUNPOD_ENDPOINT_ID`.
2. Đặt **endpoint secrets** (R2 credentials cho worker):
   `RCLONE_CONFIG_R2_TYPE=s3`, `RCLONE_CONFIG_R2_PROVIDER=Cloudflare`
   `RCLONE_CONFIG_R2_ACCESS_KEY_ID`, `RCLONE_CONFIG_R2_SECRET_ACCESS_KEY`
   `RCLONE_CONFIG_R2_ENDPOINT`, `R2_BUCKET`
3. Lưu `runpod_api_key` trong Ansible Vault (`ansible/group_vars/vault.yml`).
4. Set `rp_endpoint_id` và `r2_bucket` trong `ansible/group_vars/cloud.yml`.

### Chạy

```bash
cd ansible
# Submit job (worker: R2 source/A -> extract -> R2 extract/A)
ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=alice.mp4 -e sl_side=A
```

Client POST `/runsync` → block tới khi job xong (timeout `sl_timeout`, mặc định 600s) → in JSON kết quả `{ok, input, faces, r2_dst}`.

Tham số extract dùng chung `fs_*` (detector/aligner/extract_size/extract_norm/dedupe).

### Gradio UI (thay thế CLI)

`app/main.py` — giao diện web upload video, submit job, xem kết quả mà không cần CLI.

```bash
cp app/.env.example app/.env   # điền RUNPOD_* + R2 credentials

# Chạy bằng Docker qua Makefile
make app
# Hoặc APP_PORT=8080 APP_IMAGE=faceswap-app:dev make app

# Hoặc chạy trực tiếp:
brew install rclone
./fsenv/bin/pip install -r app/requirements.txt
./fsenv/bin/python3 app/main.py
# -> mở http://127.0.0.1:7860
```

Flow: upload video → R2 `source/<side>/` → POST `/runsync` → worker extract → R2 `extract/<side>/` → hiện face count + R2 path. Tham số extract chỉnh trong **Advanced Options** trên UI.

---

## Tham chiếu lệnh nhanh

**Cloud (Vast):** `terraform-manage-instance` | `cloud-install-faceswap` | `cloud-preflight` | `cloud-pull-train-faces` | `cloud-start-training` | `cloud-start-tensorboard` | `cloud-install-sync-cron`. Var: `faceswap_req_file`, `fs_faces_a/fs_faces_b`, `fs_train_model_dir`, `fs_trainer`, `fs_batch_size`, `fs_workspace_name`.

**Serverless (RunPod + Cloudflare R2):** `runpod-extract-faces`. Var: `rp_endpoint_id`, `sl_input`, `sl_side`, `sl_timeout`, `r2_bucket`. Endpoint secrets: `RCLONE_CONFIG_R2_*`. Ansible Vault: `runpod_api_key`.

---

## Checklist

- [ ] `cd ansible && ansible-galaxy collection install -r requirements.yml` (1 lần)
- [ ] Đặt R2 credentials (`RCLONE_CONFIG_R2_*`, `R2_BUCKET`) trong RunPod endpoint secrets
- [ ] Set `rp_endpoint_id` + `r2_bucket` trong `group_vars/cloud.yml`
- [ ] Upload video nguồn lên R2 `source/A|B/`; set `fs_workspace_name`
- [ ] `runpod-extract-faces.yml` A + B → duyệt `extract/A|B/` trên R2 → copy faces vào R2 `train/input_A|B/`
- [ ] `terraform-manage-instance.yml` → `cloud-install-faceswap.yml`
- [ ] `cloud-pull-train-faces.yml` → `cloud-preflight.yml`
- [ ] `cloud-start-training.yml` → `cloud-install-sync-cron.yml -e fs_workspace_name=<ws>`
- [ ] Xong → destroy instance

---

## Lỗi thường gặp (Troubleshooting)

| Triệu chứng | Nguyên nhân | Cách xử lý |
|-------------|-------------|-----------|
| Load ảnh lỗi `value: <class 'list'> field: NDArray` (mọi faces) | **numpy 2.5** đổi nội bộ `numpy.typing.NDArray` → vỡ deserializer alignment (`lib/align/objects.py`) | Đã **cap `numpy<2.5`** trong `_requirements_base.txt`. Instance cũ: `pip install "numpy>=2.4,<2.5"` rồi train lại |
| Lỗi tương tự nhưng **chỉ 1 phía** A *hoặc* B, numpy đã đúng | Faces extract bằng **faceswap bản cũ** → metadata alignment lệch schema | Re-extract chính folder faces đó rồi trỏ `FACES_A/B` sang output mới |
| Treo ở prompt `select the required backend` / `ModuleNotFoundError: No module named 'tensorflow'` | Chưa chọn backend → Keras 3 mặc định nhánh TensorFlow | `cloud-install-faceswap.yml` đã tự `export FACESWAP_BACKEND=nvidia` + `KERAS_BACKEND=torch`. Chạy `faceswap.py` tay thì export 2 biến này trước |
| `ERROR Side B contains fewer than 25 images` (train thoát ngay) | faceswap **bắt buộc ≥ 25 faces/phía** | Submit lại RunPod extract với `fs_dedupe=false` hoặc giảm `fs_dedup_threshold` |
| `WARNING Side X contains fewer than 250 images` | Quá ít faces → model kém (không chặn train) | Nhắm **500–5000 faces/phía**; thêm video/giảm dedupe |

> CUDA 13.0 base-image hoạt động tốt với `requirements_nvidia_13.txt` (torch cu130). Đặt biến môi trường backend **trước** mọi lệnh `faceswap.py` chạy headless.

---

## Câu hỏi chưa giải quyết

- Batch size 16 là khởi điểm — điều chỉnh theo VRAM thực tế (8/4 nếu OOM).
