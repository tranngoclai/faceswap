# Cloud Training trên vast.ai — Quy trình tổng hợp

Train faceswap trên GPU thuê tại [vast.ai](https://cloud.vast.ai).

> **⚙️ Đã chuyển toàn bộ setup/deploy sang Ansible** (`ansible/`). Các bash script cũ
> (`setup-vast.sh`, `create-cloudcopy-key.sh`, `docker-faceswap.sh`, `convert-faces.sh`)
> **đã gỡ**. Lệnh chi tiết xem **[`ansible/README.md`](../ansible/README.md)**. Bảng ánh xạ:

| Việc | Lệnh Ansible (chạy trong `ansible/`) |
|------|--------------------------------------|
| Cloud: provision VastAI/RunPod | `ansible-playbook playbooks/cloud-provision-instance.yml` (default: VastAI) or `-e enable_runpod=true -e enable_vast=false` |
| Cloud: install + GPU check | `ansible-playbook playbooks/cloud-install-faceswap.yml` |
| Cloud: train (tmux) | `ansible-playbook playbooks/cloud-start-training.yml` |
| Cloud: TensorBoard | `ansible-playbook playbooks/cloud-start-tensorboard.yml` |
| Cloud: auto cloud-sync cron | `ansible-playbook playbooks/cloud-install-sync-cron.yml` |
| Cloud: rclone push/pull | `ansible-playbook playbooks/cloud-rclone.yml -e rclone_direction=push -e rclone_remote=…` |
| RunPod: serverless health-check | `ansible-playbook playbooks/cloud-serverless-deploy.yml` |
| RunPod: serverless extract | `ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=alice.mp4 -e sl_side=A` |
| Add/edit vault secret | `ansible-playbook playbooks/vault-store-key.yml -e vault_key=x -e vault_value=y` |
| Local: build CPU image | `ansible-playbook playbooks/local-build.yml` |
| Local: extract→dedupe→sharp | `ansible-playbook playbooks/local-extract.yml -e fs_input=alice.mp4 -e fs_ws=alice` |
| Local: dedupe / sharp riêng | `ansible-playbook playbooks/local-dedupe.yml` · `local-sharp.yml` |
| Local: convert (ghép mặt) | `ansible-playbook playbooks/local-convert.yml -e fs_ws=alice` |

> **Backend:** PyTorch + Keras 3 (KHÔNG còn TensorFlow). Train cần **NVIDIA GPU + CUDA**.
> **Phân vai:** extract/convert nhẹ → chạy **local**; train nặng → **vast.ai GPU**.
> Apple Silicon/Linux có torch native: thêm `-e fs_local_backend=native` (bỏ Docker).

```
[App] upload video ───────────────────────────> [Google Drive] <workspace>/source/A|B/
[RunPod Serverless] extract <── gdrive input ──  faces ──> Drive extract/A|B/  (operator review)
[LOCAL] curate: copy approved ──────────────────────────> Drive train/input_A|B/
[VAST.AI] train <── sync inputs from Drive ──> model/ ──sync back (cron)──> Drive train/model/
[LOCAL] convert (ghép mặt) <─── pull model từ Drive ──────────────────────────────────────────┘
```

---

## Quy trình operator hoàn chỉnh (Drive-first, 13 bước)

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml          # 1 lần duy nhất

# 1. Mã hoá / rotate SA key → Ansible Vault
ansible-playbook playbooks/vault-store-gdrive-sa-key.yml

# 2. Chia sẻ Drive root folder cho SA email (xem output bước 1 để lấy email)
#    Ghi folder ID vào group_vars/cloud.yml: gdrive_root_folder_id

# 3. Cấu hình rclone gdrive local (SA key lấy từ vault — dùng bước 12 bên dưới)

# 4. Đặt endpoint secrets trong RunPod console:
#    GDRIVE_SA_JSON_B64   — SA JSON base64 (xem vault-store-gdrive-sa-key.yml output)
#    GDRIVE_ROOT_FOLDER_ID — folder ID từ bước 2

# 5. Upload video nguồn qua App → Drive <workspace>/source/A|B/
#    (App tự đặt fs_workspace_name và side; ghi fs_workspace_name vào cloud.yml)

# 6. RunPod extract A + B (đợi tới khi job terminal)
ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=alice.mp4 -e sl_side=A
ansible-playbook playbooks/runpod-extract-faces.yml -e sl_input=bob.mp4   -e sl_side=B

# 7. Duyệt mặt trong Drive extract/A|B/
#    Copy approved faces → Drive train/input_A/ và train/input_B/

# 8. Provision VastAI instance (Terraform) + setup
ansible-playbook playbooks/cloud-provision-instance.yml
ansible-playbook playbooks/cloud-install-faceswap.yml

# 9. Sync Drive inputs → VastAI /workspace/train/
ansible-playbook playbooks/cloud-pull-train-faces.yml

# 10. Preflight: kiểm tra faces / disk / GPU trước khi train
ansible-playbook playbooks/cloud-preflight.yml

# 11. Train (tmux, chạy nền)
ansible-playbook playbooks/cloud-start-training.yml -e fs_trainer=original -e fs_batch_size=16
ansible-playbook playbooks/cloud-start-tensorboard.yml                              # TensorBoard port 6006 (tuỳ chọn)

# 12. Cài cron auto-sync model → Drive mỗi 10 phút
ansible-playbook playbooks/cloud-install-sync-cron.yml
#    -> /root/cloud-sync.sh; log: /root/cloud-sync.log

# 13. Xong → stop/destroy instance; pull model để convert local
ansible-playbook playbooks/local-convert.yml -e fs_ws=alice -e fs_input=alice.mp4
#    -> kết quả ở workspace/alice/converted/
```

---

## 1. Local: extract + dedupe (Docker)

> **Vì sao Docker:** PyTorch đã **bỏ wheel macOS Intel (x86_64)**; faceswap cần `torchvision>=0.18` (không có wheel x86_64) → chạy trong **Linux CPU container** (native amd64 trên Intel, emulated trên Apple Silicon). *Apple Silicon / Linux có torch native → dùng `convert-faces.sh` trực tiếp, bỏ qua Docker.*

**Workspace theo nhân dạng** — tham số `WS` gom mọi artifact dưới `workspace/<WS>/`. Không truyền `WS` thì lấy **tên file input** (`my1.mp4` → `my1`). Train nhiều mặt thì đặt `WS` rõ ràng để không đụng nhau.

```
workspace/<WS>/
├── ref/         # ẢNH THAM CHIẾU (1 nhân dạng) — bạn bỏ vào đây
├── review/      # extract+dedupe ra đây (folder timestamp, bạn duyệt)
├── faces/       # move mặt đã duyệt vào đây (data train / ALIGNED_DIR)
├── model/       # model train xong (pull từ cloud)
└── converted/   # output convert
```

`extract` chạy **detect → dedupe → folder review có timestamp** mỗi lần (không ghi đè). Bạn duyệt, xoá mặt xấu, rồi move sang `workspace/<WS>/faces/`.

> **Biến cấu hình = `fs_*` trong `ansible/group_vars/all.yml`**, override bằng `-e`. Ánh xạ tên cũ → mới: `WS→fs_ws`, `INPUT→fs_input`, `REF_DIR→fs_ref_dir`, `REF_THRESHOLD→fs_ref_threshold`, `DEDUP_THRESHOLD→fs_dedup_threshold`, `BLUR_THRESHOLD→fs_blur_threshold`, `KEEP_RAW→fs_keep_raw`, `FACES_OUT→fs_faces_out`.

```bash
ansible-playbook playbooks/local-extract.yml -e fs_ws=alice -e fs_input=alice.mp4      # mặc định: lọc ref + dedupe
ansible-playbook playbooks/local-extract.yml -e fs_ws=alice -e fs_input=alice.mp4 -e fs_dedup_threshold=4   # giữ nhiều hơn
ansible-playbook playbooks/local-extract.yml -e fs_input=my1.mp4 -e fs_dedupe=false    # giữ TẤT CẢ faces
```

| Biến (`-e`) | Mặc định | Tác dụng |
|------|----------|----------|
| `fs_ws` | tên file input | Workspace name → mọi path dưới `workspace/<ws>/` |
| `fs_ref_dir` | `workspace/<ws>/ref` | Ảnh tham chiếu — chỉ giữ 1 nhân dạng (xem dưới) |
| `fs_ref_threshold` | `0.60` | Ngưỡng khớp mặt (cao = chặt hơn) |
| `fs_dedup_threshold` | `6` | Mức lọc trùng (0 hoặc `fs_dedupe=false` = tắt) |
| `fs_keep_raw` | `false` | `true` = giữ thêm faces raw trước dedupe |

### Lọc nhiều mặt: folder `ref/`

Frame có nhiều mặt → nếu không lọc, data lẫn nhiều người, train hỏng. Bỏ **3–20 ảnh đã duyệt, DUY NHẤT 1 người** (đa dạng góc/sáng) vào `workspace/<ws>/ref/`. Role tự thêm filter `-f`/`-l` → chỉ giữ người đó. Để trống `ref/` = lấy TẤT CẢ mặt.

> Nhiều ảnh ref **không tốt hơn**: chỉ tăng thời gian khởi động + dễ false-positive. Muốn chặt hơn → tăng `fs_ref_threshold`, đừng thêm ảnh.

### Lọc ảnh trùng (dedupe)

Mặt di chuyển chậm → frame liên tiếp gần trùng khít → train phình data, dễ overfit. Thuật toán **dHash 64-bit** bỏ ảnh có Hamming `< DEDUP_THRESHOLD` so với mọi ảnh đã giữ. PNG vẫn giữ metadata alignment → train được ngay. Đã chạy tự động trong `extract`.

| Threshold | Giữ lại (trên 787 faces) | Mức lọc |
|-----------|--------------------------|---------|
| 4 | 319 | vừa |
| **6** | **197** | **khuyến nghị** (cân bằng) |
| 8 | 137 | mạnh |
| 12 | 68 | rất mạnh (dễ mất pose hữu ích) |

> Khuyến nghị train: threshold **4–6** (giữ đa dạng góc/biểu cảm). Re-thin folder có sẵn: `ansible-playbook playbooks/local-dedupe.yml -e fs_faces_out=<dir> -e fs_dedup_threshold=6`.
> Thay thế native: `python tools.py sort -g hist -t 0.2` (gom bin để thưa tay).

### Lọc ảnh nhoè (sharp)

Ảnh out-of-focus làm giảm chất lượng model. Lệnh `sharp` đo độ nét bằng **Laplacian variance** (cao = nét). Chạy **report** trước để xem phân bố, rồi đặt `BLUR_THRESHOLD` để lọc:

```bash
ansible-playbook playbooks/local-sharp.yml -e fs_faces_out=<dir>                        # report: min/p10/p25/median/p75/max
ansible-playbook playbooks/local-sharp.yml -e fs_faces_out=<dir> -e fs_blur_threshold=100 # bỏ ảnh variance < 100
```

> Chọn ngưỡng quanh **p10–p25** của report (đừng cắt sâu quá kẻo mất frame tốt). Có thể chain ngay trong extract: `-e fs_blur_threshold=100` trên `local-extract.yml`. Native tương đương: `python tools.py sort -g blur -b 5` (gom bin, bin cuối nhoè nhất).

### Chất lượng extract (plugin)

| Biến (`-e`) | Mặc định | Ghi chú |
|------|----------|---------|
| `fs_detector` | `retinaface` | Cân bằng tốc/chất. `s3fd` = chất tối đa nhưng **rất chậm trên CPU** |
| `fs_aligner` | `hrnet` | Aligner tốt nhất (fully-rotated), nhanh hơn `fan` |
| `fs_masker` | (none) | `bisenet-fp` = mask tinh hơn nhưng chậm (extended/components vẫn tự sinh) |
| `fs_extract_size` | `512` | Kích thước face px (model phải hỗ trợ) |
| `fs_extract_norm` | `hist` | Chuẩn hoá sáng cho aligner (chất lượng tốt hơn nơi ánh sáng khó) |
| `fs_min_size` | `0` | Bỏ mặt < N% cạnh ngắn frame (vd `10` bỏ mặt quá nhỏ/mờ) |
| `fs_extract_every_n` | `1` | Lấy mỗi N frame (>1 giảm trùng tại nguồn + nhanh hơn) |

> **Trade-off CPU (Intel Mac):** plugin chất lượng cao chậm hơn nhiều (`hrnet` ~2 faces/s, `s3fd` còn chậm hơn). Cần nhanh → `-e fs_aligner=fan` hoặc giảm frame `-e fs_extract_every_n=4`. Cần chất tối đa → `-e fs_detector=s3fd -e fs_masker=bisenet-fp` (chấp nhận chậm). Train mới là việc nặng — đẩy lên GPU vast.ai.

---

## 2. vast.ai: thuê instance + train

| Mục | Khuyến nghị |
|-----|-------------|
| **GPU** | RTX 3090 / 4090 / A5000 (24GB). Tối thiểu RTX 3060 12GB |
| **Image** | `vastai/base-image` CUDA **13.0** — **KHÔNG dùng `vastai/tensorflow`** (project chạy PyTorch, TF gây xung đột CUDA) |
| **Disk** | ≥ 40–60GB |
| **Ports** | 6006 (TensorBoard), 8080 (Jupyter nếu template có) |

**Khớp CUDA ↔ requirements** (đặt `faceswap_req_file` trong `group_vars/cloud.yml`):

| Image CUDA | `faceswap_req_file` |
|-----------|-----------|
| 12.6.x | `requirements/requirements_nvidia_12.txt` (cu126) |
| 12.8 / 13.0 | `requirements/requirements_nvidia_13.txt` (cu130) |

> Template **PyTorch sẵn** (`pytorch/pytorch:2.9-cuda12.8-cudnn9-runtime`)? Dùng `-e faceswap_skip_torch=true` giữ torch của image. CUDA ↔ requirements đặt ở `group_vars/cloud.yml` (`faceswap_req_file`).
> **Jupyter** không bắt buộc (train qua CLI). **Không** train trong notebook cell (chết khi mất kết nối) — `cloud-start-training.yml` chạy trong `tmux`.

Lệnh train (xem block end-to-end mục trên). Tinh chỉnh:
```bash
ansible-playbook playbooks/cloud-start-training.yml -e fs_trainer=villain -e fs_batch_size=8   # giảm batch nếu CUDA OOM
ansible-playbook playbooks/cloud-start-tensorboard.yml                                            # TensorBoard 0.0.0.0:6006
```
`faceswap_train` dùng sẵn flag headless `-w` (preview ra file), `-s` (save), `-I` (snapshot); idempotent (bỏ qua nếu tmux session đã có). Logs TensorBoard bật mặc định.

> **Preview nằm trong data dir:** `cloud-setup` tự vá `scripts/train.py` để ghi `training_preview.png` vào **thư mục model** (`fs_train_model_dir`, vd `/workspace/train/model`) thay vì cạnh `faceswap.py`. Nhờ vậy preview + model đều nằm dưới `/workspace` → **tận dụng được Cloud Sync (Google Drive)** (mục 3).

---

## 3. Auto-sync model lên Google Drive

`cloud-install-sync-cron.yml` cài **rclone** lên instance, inject SA key từ vault, đặt **cron mỗi 10 phút** đẩy `/workspace/train/model` → Drive `<workspace>/train/model/`.

```bash
# Cài rclone + cron trên instance (chạy sau cloud-setup, bước 12 trong quy trình)
ansible-playbook playbooks/cloud-install-sync-cron.yml
#   -> /root/cloud-sync.sh; crontab */10; log: /root/cloud-sync.log
```

Xác thực Drive qua **service account JSON** (lưu trong `google-account-vault.yml`, AES256-encrypted; inject vào instance qua Ansible). Không cần token browser — SA cần quyền `Editor` trên thư mục Drive gốc đã share (bước 2).

> Gỡ cron khi xong: `ssh vast-training "crontab -r"`.

### 3b. rclone push/pull (thủ công)

```bash
ansible-playbook playbooks/cloud-rclone.yml -e rclone_direction=push -e rclone_remote=gdrive:faceswap-model
ansible-playbook playbooks/cloud-rclone.yml -e rclone_direction=pull -e rclone_remote=gdrive:faceswap-model
```

---

## 4. Convert — tham số chất lượng

`local-convert.yml` áp model lên video nguồn → output. Cần **alignments của video nguồn** (faceswap tự dò cạnh input nếu để trống `fs_alignments`). Frame nhiều mặt → đặt `fs_ref_dir` để chỉ ghép 1 người. Tất cả là `fs_*` var (`-e`):

| Biến (`-e`) | Giá trị | Tác dụng |
|------|---------|----------|
| `fs_writer` | `ffmpeg` / `opencv` / `pillow` | Định dạng output (ffmpeg = video) |
| `fs_color_adj` | `avg-color`, `color-transfer`, `match-hist`, `seamless-clone`, `none` | Khớp màu mặt với nền |
| `fs_mask_type` | `extended`, `components`, `none`... | Vùng mặt ghép |
| `fs_output_scale` | `100` | % kích thước so với gốc |
| `fs_aligned_dir` | — | Folder faces đã duyệt để giới hạn mặt được ghép |

---

## 5. Serverless extract — RunPod + Google Drive

Extract faces theo **job, scale-to-zero** trên [RunPod Serverless](https://runpod.io) (tách hẳn khỏi train trên Vast). Worker xác thực vào Google Drive bằng **service account JSON** (lưu trong RunPod endpoint secret), kéo video input từ Drive, extract trên GPU, đẩy faces ngược lại Drive.

> Không có bước "deploy" — endpoint tạo **1 lần** trong RunPod console; playbook chỉ health-check.

### Layout Google Drive

```
<fs_workspace_name>/
├── source/A/        # video nguồn upload lên (từ App)
├── source/B/
├── extract/A/       # RunPod extract output — operator review tại đây
├── extract/B/
├── train/
│   ├── input_A/     # operator copy faces đã duyệt vào đây
│   ├── input_B/
│   └── model/       # artifacts sync về từ VastAI
└── logs/
```

### Setup 1 lần

1. Tạo serverless endpoint trong **RunPod console** (image: `ghcr.io/tranngoclai/faceswap-sl:<tag>`) → ghi lại `RUNPOD_ENDPOINT_ID`.
2. Đặt **endpoint secrets** (dùng cho worker xác thực vào Drive):
   `GDRIVE_SA_JSON_B64` — service account JSON đã base64-encode (`ansible-playbook playbooks/vault-store-gdrive-sa-key.yml`).
   `GDRIVE_ROOT_FOLDER_ID` — ID thư mục Drive gốc (share folder này cho SA email).
3. Lưu `runpod_api_key` trong Ansible Vault (`ansible/group_vars/vault.yml`).
4. Set `rp_endpoint_id` và `gdrive_root_folder_id` trong `ansible/group_vars/cloud.yml`.
5. Cấu hình rclone gdrive local: `ansible-playbook playbooks/cloud-install-sync-cron.yml` (dùng SA key từ `google-account-vault.yml`).

### Chạy

```bash
cd ansible
# Health-check endpoint
ansible-playbook playbooks/cloud-serverless-deploy.yml
# Submit job (worker: Drive source/A -> extract -> Drive extract/A)
ansible-playbook playbooks/runpod-extract-faces.yml \
  -e sl_input=alice.mp4 -e sl_side=A
```

Tham số extract dùng chung `fs_*` (detector/aligner/extract_size/extract_norm/dedupe). Client POST `/runsync` → block tới khi job xong (timeout `sl_timeout`, mặc định 600s) → in JSON kết quả `{ok, input, faces, gdrive_dst}`.

### Gradio UI (thay thế CLI)

`app/main.py` — giao diện web upload video, submit job, xem kết quả mà không cần CLI.

```bash
# Cài deps (1 lần)
./fsenv/bin/pip install gradio python-dotenv

# Copy template và điền giá trị
cp app/.env.example app/.env
# chỉnh app/.env: RUNPOD_API_KEY, RUNPOD_ENDPOINT_ID, GDRIVE_ROOT_FOLDER_ID, GDRIVE_SA_JSON_B64

./fsenv/bin/python3 app/main.py
# -> mở http://127.0.0.1:7860
```

Env vars được load từ `app/.env` (dùng `python-dotenv`). Template đầy đủ ở `app/.env.example`. File `app/.env` đã được gitignore.

Flow: upload video → Drive `source/<side>/` → POST `/runsync` → worker extract → Drive `extract/<side>/` → hiện face count + Drive path + raw JSON. Tham số extract (detector/aligner/extract_size/extract_norm/dedupe/timeout) chỉnh trong **Advanced Options** trên UI.

---

## Tham chiếu lệnh nhanh

Tất cả qua Ansible trong `ansible/` (chi tiết: [`ansible/README.md`](../ansible/README.md)). Cấu hình ở `group_vars/`, override bằng `-e`.

**Local:** `local-build` | `local-extract` (detect→dedupe→sharp→review) | `local-dedupe` | `local-sharp` | `local-convert`. Var: `fs_ws`, `fs_input`, `fs_ref_dir`, `fs_dedup_threshold`, `fs_blur_threshold`, `fs_detector`/`fs_aligner`, `fs_local_backend` (docker|native).

**Cloud (Vast):** `terraform-gpu` | `cloud-setup` | `cloud-train` | `cloud-board` | `cloud-cloudsync` | `cloud-rclone`. Var: `faceswap_req_file`, `fs_faces_a/fs_faces_b`, `fs_train_model_dir`, `fs_trainer`, `fs_batch_size`.

**Serverless (RunPod + Google Drive):** `cloud-serverless-deploy` (health-check) | `cloud-serverless-extract`. Var: `rp_endpoint_id`, `sl_input`, `sl_side`, `sl_timeout`. Endpoint secrets: `GDRIVE_SA_JSON_B64`, `GDRIVE_ROOT_FOLDER_ID`. Ansible Vault: `runpod_api_key`.

---

## Checklist

- [ ] `cd ansible && ansible-galaxy collection install -r requirements.yml` (1 lần)
- [ ] `vault-store-gdrive-sa-key.yml` → share Drive folder → ghi `gdrive_root_folder_id` vào `cloud.yml`
- [ ] Đặt `GDRIVE_SA_JSON_B64` + `GDRIVE_ROOT_FOLDER_ID` trong RunPod endpoint secrets
- [ ] Upload video nguồn qua App → Drive `source/A|B/`; ghi `fs_workspace_name` vào `cloud.yml`
- [ ] `runpod-extract-faces.yml` A + B → duyệt `extract/A|B/` → copy vào `train/input_A|B/`
- [ ] `cloud-provision-instance.yml` → `cloud-install-faceswap.yml` → `cloud-pull-train-faces.yml` (terraform manages cc_instance_id / rp_pod_id)
- [ ] `cloud-preflight.yml` → `cloud-start-training.yml` → `cloud-install-sync-cron.yml` (cron)
- [ ] Xong → destroy instance; `local-convert.yml` để ghép mặt

---

## Lỗi thường gặp (Troubleshooting)

| Triệu chứng | Nguyên nhân | Cách xử lý |
|-------------|-------------|-----------|
| Load ảnh lỗi `value: <class 'list'> field: NDArray` (mọi faces) | **numpy 2.5** đổi nội bộ `numpy.typing.NDArray` → vỡ deserializer alignment (`lib/align/objects.py`) | Đã **cap `numpy<2.5`** trong `_requirements_base.txt`. Instance cũ: `pip install "numpy>=2.4,<2.5"` rồi train lại |
| Lỗi tương tự nhưng **chỉ 1 phía** A *hoặc* B, numpy đã đúng | Faces extract bằng **faceswap bản cũ** → metadata alignment lệch schema | Re-extract chính folder faces đó: `python faceswap.py extract -i <faces_dir> -o <out_dir> -D s3fd -A fan` rồi trỏ `FACES_A/B` sang `<out_dir>` |
| Treo ở prompt `select the required backend` / `ModuleNotFoundError: No module named 'tensorflow'` | Chưa chọn backend → Keras 3 mặc định nhánh TensorFlow | `setup-vast.sh` đã tự `export FACESWAP_BACKEND=nvidia` + `KERAS_BACKEND=torch`. Chạy `faceswap.py` tay thì export 2 biến này trước |
| `ERROR Side B contains fewer than 25 images` (train thoát ngay) | faceswap **bắt buộc ≥ 25 faces/phía** | Extract thêm faces từ video nguồn (bỏ/giảm dedupe): `python faceswap.py extract -i <video> -o <faces_dir> -D s3fd -A fan` |
| `WARNING Side X contains fewer than 250 images` | Quá ít faces → model kém (không chặn train) | Nhắm **500–5000 faces/phía**; thêm video/giảm dedupe |
| `python: command not found` trên instance | Image chỉ có `python3`, chưa activate venv | `setup-vast.sh` tự fallback `python3`. Hoặc `source /venv/main/bin/activate` (vast base-image) |

> CUDA 13.0 base-image hoạt động tốt với `requirements_nvidia_13.txt` (torch cu130). Đặt biến môi trường backend **trước** mọi lệnh `faceswap.py` chạy headless.

---

## Câu hỏi chưa giải quyết

- Batch size 16 là khởi điểm — điều chỉnh theo VRAM thực tế (8/4 nếu OOM).
- Bước extract có thể cần thêm flag tùy chất lượng nguồn (ảnh/video).
