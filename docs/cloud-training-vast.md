# Cloud Training trên vast.ai — Quy trình tổng hợp

Train faceswap trên GPU thuê tại [vast.ai](https://cloud.vast.ai). 3 script ở repo root:

| Script | Chạy ở đâu | Lệnh |
|--------|-----------|------|
| **`docker-faceswap.sh`** | Local qua Docker (**bắt buộc trên Intel Mac**) | build / extract / dedupe / convert / shell |
| **`convert-faces.sh`** | Local có torch native (Apple Silicon / Linux) | extract / convert |
| **`setup-vast.sh`** | Instance cloud | install / check / train / board / sync / pull |

> **Backend:** PyTorch 2.9 + Keras 3 (KHÔNG còn TensorFlow). Train cần **NVIDIA GPU + CUDA**.
> **Phân vai:** extract/convert nhẹ → chạy **local**; train nặng → **vast.ai GPU**.

```
[LOCAL] extract+dedupe (A,B) ──upload──> [VAST.AI] train ──sync──> [Google Drive]
[LOCAL] convert (ghép mặt) <─────────────────────────────── pull ──┘
```

---

## Lệnh chạy hoàn chỉnh (end-to-end)

Ví dụ ghép mặt **alice → bob** (mỗi người 1 workspace riêng dưới `workspace/<WS>/`).

```bash
# === 0. LOCAL: build image Docker (1 lần duy nhất) ===
cd ~/Projects/faceswap
./docker-faceswap.sh build

# === 1. LOCAL: ảnh tham chiếu + extract (lọc 1 người + dedupe tự động) ===
mkdir -p workspace/alice/ref workspace/bob/ref
#   bỏ 5-20 ảnh alice vào workspace/alice/ref/  (đa dạng góc/sáng)
#   bỏ 5-20 ảnh bob   vào workspace/bob/ref/
WS=alice INPUT=alice.mp4 ./docker-faceswap.sh extract   # -> workspace/alice/review/<ts>/
WS=bob   INPUT=bob.mp4   ./docker-faceswap.sh extract   # -> workspace/bob/review/<ts>/

# === 2. LOCAL: duyệt review -> gom data train -> nén upload ===
mkdir -p workspace/alice/faces workspace/bob/faces
mv workspace/alice/review/<ts>/*.png workspace/alice/faces/   # sau khi xoá mặt xấu
mv workspace/bob/review/<ts>/*.png   workspace/bob/faces/
tar czf faces.tar.gz workspace/alice/faces workspace/bob/faces

# === 3. CLOUD (vast.ai, trong SSH/Jupyter terminal): train ===
scp -P <PORT> setup-vast.sh faces.tar.gz root@<HOST>:~/
REQ_FILE=requirements/requirements_nvidia_13.txt ./setup-vast.sh all   # -> CUDA available: True
tar xzf faces.tar.gz -C ~/faceswap/
tmux new -s fs
FACES_A=workspace/alice/faces FACES_B=workspace/bob/faces \
MODEL_DIR=workspace/alice/model TRAINER=phaze-a BATCH_SIZE=16 \
SYNC_REMOTE="gdrive:faceswap-alice" ./setup-vast.sh train
#   Ctrl+B rồi D để detach. Theo dõi loss: ./setup-vast.sh board  (port 6006)

# === 4. LOCAL: pull model + convert (ghép mặt) ===
SYNC_REMOTE="gdrive:faceswap-alice" MODEL_DIR=workspace/alice/model ./setup-vast.sh pull
WS=alice INPUT=alice.mp4 ALIGNED_DIR=workspace/alice/faces ./docker-faceswap.sh convert
#   -> kết quả ở workspace/alice/converted/
```

> Thay `<ts>` bằng tên folder timestamp thật script in ra (vd `20260630-012304`).
> **Bản gọn nhất** (1 video, WS lấy từ tên file): bỏ `WS=...`, chạy `INPUT=my1.mp4 ./docker-faceswap.sh extract` → workspace `my1`.

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

```bash
WS=alice INPUT=alice.mp4 ./docker-faceswap.sh extract           # mặc định: lọc ref + dedupe
WS=alice INPUT=alice.mp4 DEDUP_THRESHOLD=4 ./docker-faceswap.sh extract   # giữ nhiều hơn
INPUT=my1.mp4 ./docker-faceswap.sh extract dedupe=false         # giữ TẤT CẢ faces
```

| Biến | Mặc định | Tác dụng |
|------|----------|----------|
| `WS` | tên file input | Workspace name → mọi path dưới `workspace/<WS>/` |
| `REF_DIR` | `workspace/<WS>/ref` | Ảnh tham chiếu — chỉ giữ 1 nhân dạng (xem dưới) |
| `REF_THRESHOLD` | `0.60` | Ngưỡng khớp mặt (cao = chặt hơn) |
| `DEDUP_THRESHOLD` | `6` | Mức lọc trùng (0 hoặc `dedupe=false` = tắt) |
| `KEEP_RAW` | `0` | `1` = giữ thêm faces raw trước dedupe |

### Lọc nhiều mặt: folder `ref/`

Frame có nhiều mặt → nếu không lọc, data lẫn nhiều người, train hỏng. Bỏ **3–20 ảnh đã duyệt, DUY NHẤT 1 người** (đa dạng góc/sáng) vào `workspace/<WS>/ref/`. Script tự thêm filter `-f`/`-l` → chỉ giữ người đó. Để trống `ref/` = lấy TẤT CẢ mặt.

> Nhiều ảnh ref **không tốt hơn**: chỉ tăng thời gian khởi động + dễ false-positive. Muốn chặt hơn → tăng `REF_THRESHOLD`, đừng thêm ảnh.

### Lọc ảnh trùng (dedupe)

Mặt di chuyển chậm → frame liên tiếp gần trùng khít → train phình data, dễ overfit. Thuật toán **dHash 64-bit** bỏ ảnh có Hamming `< DEDUP_THRESHOLD` so với mọi ảnh đã giữ. PNG vẫn giữ metadata alignment → train được ngay. Đã chạy tự động trong `extract`.

| Threshold | Giữ lại (trên 787 faces) | Mức lọc |
|-----------|--------------------------|---------|
| 4 | 319 | vừa |
| **6** | **197** | **khuyến nghị** (cân bằng) |
| 8 | 137 | mạnh |
| 12 | 68 | rất mạnh (dễ mất pose hữu ích) |

> Khuyến nghị train: threshold **4–6** (giữ đa dạng góc/biểu cảm). Re-thin folder có sẵn: `FACES_OUT=<dir> DEDUP_THRESHOLD=6 ./docker-faceswap.sh dedupe`.
> Thay thế native: `python tools.py sort -g hist -t 0.2` (gom bin để thưa tay).

### Lọc ảnh nhoè (sharp)

Ảnh out-of-focus làm giảm chất lượng model. Lệnh `sharp` đo độ nét bằng **Laplacian variance** (cao = nét). Chạy **report** trước để xem phân bố, rồi đặt `BLUR_THRESHOLD` để lọc:

```bash
FACES_OUT=<dir> ./docker-faceswap.sh sharp                    # report: min/p10/p25/median/p75/max
FACES_OUT=<dir> BLUR_THRESHOLD=100 ./docker-faceswap.sh sharp # bỏ ảnh variance < 100
```

> Chọn ngưỡng quanh **p10–p25** của report (đừng cắt sâu quá kẻo mất frame tốt). Có thể chain ngay trong extract: `BLUR_THRESHOLD=100 ./docker-faceswap.sh extract`. Native tương đương: `python tools.py sort -g blur -b 5` (gom bin, bin cuối nhoè nhất).

### Chất lượng extract (plugin)

| Biến | Mặc định | Ghi chú |
|------|----------|---------|
| `DETECTOR` | `retinaface` | Cân bằng tốc/chất. `s3fd` = chất tối đa nhưng **rất chậm trên CPU** |
| `ALIGNER` | `hrnet` | Aligner tốt nhất (fully-rotated), nhanh hơn `fan` |
| `MASKER` | (none) | `bisenet-fp` = mask tinh hơn nhưng chậm (extended/components vẫn tự sinh) |
| `EXTRACT_SIZE` | `512` | Kích thước face px (model phải hỗ trợ) |
| `EXTRACT_NORM` | `hist` | Chuẩn hoá sáng cho aligner (chất lượng tốt hơn nơi ánh sáng khó) |
| `MIN_SIZE` | `0` | Bỏ mặt < N% cạnh ngắn frame (vd `10` bỏ mặt quá nhỏ/mờ) |
| `EXTRACT_EVERY_N` | `1` | Lấy mỗi N frame (>1 giảm trùng tại nguồn + nhanh hơn) |

> **Trade-off CPU (Intel Mac):** plugin chất lượng cao chậm hơn nhiều (`hrnet` ~2 faces/s, `s3fd` còn chậm hơn). Cần nhanh → `ALIGNER=fan` hoặc giảm frame `EXTRACT_EVERY_N=4`. Cần chất tối đa → `DETECTOR=s3fd MASKER=bisenet-fp` (chấp nhận chậm). Train mới là việc nặng — đẩy lên GPU vast.ai.

---

## 2. vast.ai: thuê instance + train

| Mục | Khuyến nghị |
|-----|-------------|
| **GPU** | RTX 3090 / 4090 / A5000 (24GB). Tối thiểu RTX 3060 12GB |
| **Image** | `vastai/base-image` CUDA **12.8** — **KHÔNG dùng `vastai/tensorflow`** (project chạy PyTorch, TF gây xung đột CUDA) |
| **Disk** | ≥ 40–60GB |
| **Ports** | 6006 (TensorBoard), 8080 (Jupyter nếu template có) |

**Khớp CUDA ↔ requirements:**

| Image CUDA | `REQ_FILE` |
|-----------|-----------|
| 12.6.x | `requirements/requirements_nvidia_12.txt` (cu126) |
| 12.8 / 13.0 | `requirements/requirements_nvidia_13.txt` (cu130) |

> Template **PyTorch sẵn** (`pytorch/pytorch:2.9-cuda12.8-cudnn9-runtime`)? Dùng `SKIP_TORCH=1` giữ torch của image.
> **Jupyter** không bắt buộc (train qua CLI). **Không** train trong notebook cell (chết khi mất kết nối) — luôn `tmux`.

Lệnh train (xem block end-to-end mục trên). Tinh chỉnh:
```bash
TRAINER=villain BATCH_SIZE=8 ./setup-vast.sh train   # giảm batch nếu CUDA OOM
./setup-vast.sh board                                # TensorBoard 0.0.0.0:6006
```
Script dùng sẵn flag headless `-w` (preview ra file), `-s` (save), `-I` (snapshot). Logs TensorBoard bật mặc định.

> **Preview nằm trong data dir:** `install` tự vá `scripts/train.py` để ghi `training_preview.png` vào **thư mục model** (`MODEL_DIR`, vd `/workspace/train/model`) thay vì cạnh `faceswap.py`. Nhờ vậy preview + model đều nằm dưới `/workspace` → **tận dụng được Cloud Sync (Google Drive) của vast.ai console** (sync cả `/workspace`), khỏi cần rclone. Muốn auto-sync bằng rclone thì vẫn dùng `SYNC_REMOTE` (mục 3).

---

## 3. Auto-sync Google Drive (rclone)

**Config 1 lần** — trên LOCAL (có browser) lấy token, trên INSTANCE paste vào:
```bash
# LOCAL
rclone authorize "drive"        # đăng nhập Google -> copy token JSON
# INSTANCE
curl https://rclone.org/install.sh | bash
rclone config create gdrive drive config_is_local=false token='{...token...}'
rclone mkdir gdrive:faceswap-alice && rclone lsd gdrive:   # test
```

**3 lớp bảo vệ tiến độ** (tích hợp trong `setup-vast.sh train`):
1. **Định kỳ** — sync mỗi `SYNC_INTERVAL`s (mặc định 1800 = 30 phút)
2. **Khi thoát** — `trap EXIT/INT/TERM` sync lần cuối khi train dừng / Ctrl+C / stop
3. **Thủ công** — `./setup-vast.sh sync`

> Giảm rủi ro: `SYNC_INTERVAL=600`. Kill cứng (SIGKILL/mất điện) thì `trap` không chạy → lớp định kỳ là dự phòng.

### 3b. Auto-sync bằng vast.ai Cloud Copy (không cần rclone)

Tận dụng **cloud connection** sẵn trong vast.ai console (Settings → Cloud connections, vd Google Drive) → cron **trên instance** tự gọi API đẩy `/workspace` lên Drive. Độc lập máy local.

```bash
# 1) LOCAL: đẩy API key lên instance (cron cần để gọi vast API)
scp ~/.config/vastai/vast_api_key root@<HOST>:~/.config/vastai/vast_api_key
vastai show connections        # lấy CONNECTION_ID (cloud_type=drive)

# 2) INSTANCE: cài cron auto cloud-copy (mỗi 10 phút) — key qua env, KHÔNG ghi file key
VAST_API_KEY=<scoped> CC_INSTANCE_ID=<id> CC_CONNECTION_ID=<conn> \
SYNC_SRC=/workspace/train CC_DST=/faceswap-train ./setup-vast.sh cloudsync
#   -> /root/cloud-sync.sh + crontab (dòng VAST_API_KEY + */10); log: /root/cloud-sync.log
```

**Bước 0 (khuyến nghị) — tạo API key quyền tối thiểu trước khi train.** Chạy LOCAL (cần admin key đã `vastai set api-key`):

```bash
VAST_API_KEY=$(./create-cloudcopy-key.sh)   # scoped key (chỉ cloud-copy) -> dùng cho cloudsync
./create-cloudcopy-key.sh --set-env-var      # + set vast ACCOUNT env-var (auto-inject instance mới)
```

Permission tối thiểu (đã kiểm chứng): `instance_write → api.commands.rclone → POST` (route cloud-copy là `/api/v0/commands/rclone/`). Key này lộ cũng **không destroy instance / tiêu credit** được.

**Auth qua env var, không file key:** vastai đọc key theo thứ tự `--api-key` → **`VAST_API_KEY`** → file `~/.config/vastai/vast_api_key`. `cloudsync` ghi `VAST_API_KEY` vào **header crontab** (cron có env tối giản nên job mới thấy được); set thêm **account env-var** để instance mới tự có.

> ⚠️ Lưu ý:
> - Tạo key con phải dùng **admin/primary key** (key trình duyệt lưu sẵn → `401 not authorized to create ... with these permissions`).
> - `vastai create api-key --raw` in **không phải JSON** → script gọi REST bằng curl.
> - Endpoint đúng là `api.commands.rclone` (không phải `api.instance.cloud-copy` → 401).
> - **PATH cho cron:** vastai pre-install ở `/opt/instance-tools/bin` (KHÔNG ở venv) → `cloud-sync.sh` phải set PATH gồm path này, nếu không cron báo `vastai: command not found`.
> - Gỡ cron khi xong: `crontab -l | grep -v cloud-sync.sh | crontab -`.

---

## 4. Convert — tham số chất lượng

`convert` áp model lên video nguồn → output. Cần **alignments của video nguồn** (faceswap tự dò cạnh input nếu để trống `ALIGNMENTS`). Frame nhiều mặt → đặt cùng `WS`/`REF_DIR` để chỉ ghép 1 người.

| Biến | Giá trị | Tác dụng |
|------|---------|----------|
| `WRITER` | `ffmpeg` / `opencv` / `pillow` | Định dạng output (ffmpeg = video) |
| `COLOR_ADJ` | `avg-color`, `color-transfer`, `match-hist`, `seamless-clone`, `none` | Khớp màu mặt với nền |
| `MASK_TYPE` | `extended`, `components`, `none`... | Vùng mặt ghép |
| `OUTPUT_SCALE` | `100` | % kích thước so với gốc |
| `ALIGNED_DIR` | — | Folder faces đã duyệt để giới hạn mặt được ghép |

---

## Tham chiếu lệnh nhanh

**`docker-faceswap.sh`** (local): `build` | `extract` (detect→dedupe→review timestamp) | `dedupe` (re-thin folder) | `sharp` (report/lọc nhoè) | `convert` | `shell`. Biến chính: `WS`, `REF_DIR`, `DEDUP_THRESHOLD`, `BLUR_THRESHOLD`, `DETECTOR`/`ALIGNER`, `MODEL_DIR`, `ALIGNED_DIR`.

**`setup-vast.sh`** (cloud): `install` | `check` | `train` | `board` | `sync` | `pull` | `all`. Biến chính: `REQ_FILE`, `FACES_A/B`, `MODEL_DIR`, `TRAINER`, `BATCH_SIZE`, `SYNC_REMOTE`.

---

## Checklist

- [ ] `./docker-faceswap.sh build` (1 lần)
- [ ] Bỏ ảnh tham chiếu vào `workspace/<WS>/ref/`
- [ ] `extract` mỗi nhân dạng → duyệt review → move sang `faces/`
- [ ] Thuê instance `vastai/base-image` CUDA 12.8 → `./setup-vast.sh all` thấy `CUDA available: True`
- [ ] Upload faces + config rclone gdrive
- [ ] `train` trong `tmux` với `SYNC_REMOTE`; theo dõi loss qua TensorBoard
- [ ] `pull` model về local → `convert`

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
