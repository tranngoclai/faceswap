# Runbook: Tạo Vast.ai Instance + Chuẩn bị Train

Mục tiêu: thuê GPU instance trên vast.ai, setup môi trường faceswap, sẵn sàng chạy train.

---

## Điều kiện tiên quyết

| Item | Trạng thái cần đạt |
|------|--------------------|
| `vastai` CLI đã cài | `vastai --version` không lỗi |
| Admin API key đã set | `vastai set api-key <primary_key>` |
| SSH key đã có | `~/.ssh/id_ed25519` (hoặc bất kỳ key nào) |
| Ansible collection | `cd ansible && ansible-galaxy collection install -r requirements.yml` |
| Faces A & B đã extract | `workspace/train/input_aligned/` và `workspace/train/output/faces_full/` (≥ 500 faces/phía) |

---

## Bước 1 — Tìm & Thuê Instance

### 1a. Tìm máy phù hợp

```bash
# RTX 3090/4090 24GB, CUDA ≥ 12.8, disk ≥ 60GB, giá hợp lý
vastai search offers \
  'gpu_name=RTX_4090 num_gpus=1 disk_space>=60 cuda_vers>=12.8' \
  --order-by dph_total \
  --limit 10
```

> Thay `RTX_4090` bằng `RTX_3090` hoặc `A5000` nếu không có / quá đắt.  
> Cột `dph_total` = giá $/h. Ghi lại `ID` của offer chọn được.

### 1b. Thuê instance

```bash
vastai create instance <OFFER_ID> \
  --image vastai/base-image \
  --disk 60 \
  --ssh \
  --env 'FACESWAP_BACKEND=nvidia KERAS_BACKEND=torch' \
  --onstart-cmd "echo vast-ready"
```

> **Image quan trọng:** Dùng `vastai/base-image` (CUDA 13.0).  
> **KHÔNG** dùng `vastai/tensorflow` — gây xung đột CUDA với PyTorch.

### 1c. Lấy thông tin SSH

```bash
# Đợi ~30-60s rồi check
vastai show instances

# Lấy SSH command
vastai ssh-url <INSTANCE_ID>
# Output dạng: ssh root@<host> -p <port>
```

---

## Bước 2 — Cấu hình SSH Local

Thêm vào `~/.ssh/config` (thay host/port từ bước 1c):

```
Host vast-training
    HostName <host_ip_or_domain>
    Port <port>
    User root
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
```

Kiểm tra kết nối:

```bash
ssh vast-training "nvidia-smi && echo SSH_OK"
```

Output cần thấy GPU (RTX 4090 / 3090) + `SSH_OK`.

---

## Bước 3 — Cập nhật Inventory & Config

### 3a. Inventory đã đúng sẵn

`ansible/inventory.ini` dùng alias `vast-training` (SSH config quản lý host/port) → không cần chỉnh.

### 3b. Kiểm tra `group_vars/cloud.yml`

```bash
cat ansible/group_vars/cloud.yml
```

Xác nhận các path phù hợp với dữ liệu thực tế:

| Biến | Giá trị mặc định | Ghi chú |
|------|-----------------|---------|
| `fs_faces_a` | `/workspace/train/input_aligned` | Faces nhân vật A |
| `fs_faces_b` | `/workspace/train/output/faces_full` | Faces nhân vật B |
| `fs_train_model_dir` | `/workspace/train/model` | Model output |
| `faceswap_req_file` | `requirements/requirements_nvidia_13.txt` | CUDA 13 (base-image mặc định) |

Override khi chạy nếu cần: `-e fs_faces_a=/workspace/custom/path`.

---

## Bước 4 — Setup Instance

```bash
cd ansible
ansible-playbook playbooks/cloud-setup.yml
```

Playbook này sẽ:
- Clone repo faceswap lên instance
- Cài dependencies khớp CUDA (`requirements_nvidia_13.txt` → torch cu130)
- Export backend env vars (`FACESWAP_BACKEND=nvidia`, `KERAS_BACKEND=torch`)
- Vá `scripts/train.py` để preview ghi vào model dir (phục vụ cloud sync)
- Kiểm tra GPU (`nvidia-smi`)

**Kiểm tra thành công:** playbook kết thúc không có task `FAILED`.

---

## Bước 5 — Upload Faces lên Instance

```bash
# Upload faces A
rsync -avz --progress \
  workspace/train/input_aligned/ \
  vast-training:/workspace/train/input_aligned/

# Upload faces B
rsync -avz --progress \
  workspace/train/output/faces_full/ \
  vast-training:/workspace/train/output/faces_full/
```

Xác nhận số lượng:

```bash
ssh vast-training "echo A: \$(ls /workspace/train/input_aligned | wc -l) faces && echo B: \$(ls /workspace/train/output/faces_full | wc -l) faces"
```

> Cần **≥ 25 faces/phía** (hard limit của faceswap). Khuyến nghị **500–5000/phía**.

---

## Bước 6 — Tạo Scoped API Key (cho Cloud Sync)

```bash
# Tạo key quyền tối thiểu (chỉ instance_write/rclone)
VAST_ADMIN_KEY=<primary_key> ansible-playbook playbooks/provision-cloudsync-key.yml
# → in ra scoped key, copy lại
```

---

## Bước 7 — Bật Auto-Sync lên Google Drive

```bash
VAST_API_KEY=<scoped_key> ansible-playbook playbooks/cloud-cloudsync.yml
```

Cron sẽ đẩy `/workspace/train` lên Google Drive mỗi 10 phút.

Kiểm tra:

```bash
ssh vast-training "crontab -l"
# Cần thấy dòng */10 ... cloud-sync.sh
```

---

## Bước 8 — Xác nhận Sẵn sàng Train

```bash
ssh vast-training bash << 'EOF'
echo "=== GPU ===" && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
echo "=== Python ===" && /venv/main/bin/python -c "import torch; print('CUDA:', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0))"
echo "=== Faces A ===" && ls /workspace/train/input_aligned | wc -l
echo "=== Faces B ===" && ls /workspace/train/output/faces_full | wc -l
echo "=== READY ==="
EOF
```

Kết quả mong đợi:

```
=== GPU ===
NVIDIA GeForce RTX 4090, 24576 MiB
=== Python ===
CUDA: True | NVIDIA GeForce RTX 4090
=== Faces A ===
734
=== Faces B ===
612
=== READY ===
```

---

## Bước 9 — Bắt đầu Train

```bash
cd ansible
ansible-playbook playbooks/cloud-train.yml \
  -e fs_trainer=original \
  -e fs_batch_size=16
```

> Giảm `fs_batch_size` xuống `8` hoặc `4` nếu gặp CUDA OOM.

Theo dõi loss qua TensorBoard:

```bash
ansible-playbook playbooks/cloud-board.yml
# Mở http://<vast_host>:6006 trên trình duyệt
```

---

## Checklist Nhanh

```
[ ] vastai CLI + admin key sẵn sàng
[ ] Faces A/B đã extract local (≥ 500/phía)
[ ] Thuê instance: vastai/base-image, CUDA 13, disk ≥ 60GB
[ ] SSH config → ssh vast-training hoạt động
[ ] ansible-playbook cloud-setup.yml → không FAILED
[ ] rsync faces A & B lên /workspace/train/
[ ] provision-cloudsync-key.yml → lấy scoped key
[ ] cloud-cloudsync.yml → cron chạy
[ ] Verify: GPU + CUDA + faces count OK
[ ] cloud-train.yml → tmux session "fs" đang chạy
```

---

## Troubleshooting

| Triệu chứng | Nguyên nhân | Fix |
|-------------|-------------|-----|
| `ssh: connect to host vast-training` | SSH config chưa đúng hoặc instance chưa ready | Đợi 60s, kiểm tra `vastai show instances` rồi cập nhật `~/.ssh/config` |
| `FAILED: cloud-setup` tại bước cài deps | CUDA version không khớp req file | Đổi `faceswap_req_file` trong `cloud.yml` theo bảng CUDA↔req trong `cloud-training-vast.md` |
| CUDA OOM khi train | Batch size quá lớn | `-e fs_batch_size=8` hoặc `4` |
| `ERROR Side B < 25 images` | Quá ít faces | Re-extract, giảm `fs_dedup_threshold` |
| Cloud sync không chạy | PATH cron thiếu `/opt/instance-tools/bin` | `cloud-setup.yml` đã vá; kiểm tra `cloud-sync.sh` có PATH đúng |

---

## Dọn dẹp Sau Train

```bash
# Pull model về local
cd ansible
ansible-playbook playbooks/cloud-rclone.yml \
  -e rclone_direction=pull \
  -e rclone_remote=gdrive:faceswap-train

# Xoá cron trước khi destroy instance
ssh vast-training "crontab -r"

# Destroy instance (không thể hoàn tác!)
vastai destroy instance <INSTANCE_ID>
```
