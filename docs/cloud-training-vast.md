# Cloud Training trên vast.ai — Quy trình tổng hợp

Hướng dẫn train model faceswap trên GPU thuê tại [vast.ai](https://cloud.vast.ai), kèm 2 script tự động ở repo root:

- **`setup-vast.sh`** — chạy trên instance cloud (install / check / train / board / sync / pull)
- **`convert-faces.sh`** — chạy ở local (extract / convert)

> **Backend:** bản faceswap này dùng **PyTorch 2.9 + Keras 3** (KHÔNG còn TensorFlow). Cần **NVIDIA GPU + CUDA**.

---

## Tổng quan luồng

```
[LOCAL]  extract faces (A,B) ──upload──> [VAST.AI]  train ──sync──> [Google Drive]
                                                                          │ pull
[LOCAL]  convert (ghép mặt) <───────────────────────────────────────────┘
```

| Bước | Chạy ở đâu | Vì sao |
|------|-----------|--------|
| Extract | Local (CPU) | Không tốn GPU thuê |
| Train | vast.ai (GPU) | Việc nặng duy nhất cần GPU mạnh |
| Convert | Local | Nhẹ GPU, không cần thuê |

---

## 1. Chuẩn bị dữ liệu (LOCAL)

Train cần **faces đã extract sẵn** của 2 nhân dạng:
- `workspace/faces_A` — nhân dạng A (mặt nguồn)
- `workspace/faces_B` — nhân dạng B (mặt đích sẽ ghép lên)

```bash
# Extract faces từ ảnh/video nguồn (lặp lại cho cả A và B)
python faceswap.py extract -i <media_A> -o workspace/faces_A
python faceswap.py extract -i <media_B> -o workspace/faces_B

# Nén để upload
tar czf faces.tar.gz workspace/faces_A workspace/faces_B
```

> **Ảnh/video có nhiều mặt?** Mặc định extract lấy TẤT CẢ mặt → data lẫn lộn nhiều người, train hỏng. Xem mục [Xử lý ảnh nhiều mặt](#xu-ly-anh-nhieu-mat-multi-face) bên dưới.

---

## 1b. Xử lý ảnh nhiều mặt (multi-face) {#xu-ly-anh-nhieu-mat-multi-face}

Mục tiêu: thư mục faces chỉ chứa **một nhân dạng**.

### Cách làm: folder reference đã duyệt (khuyến nghị)

Tạo một folder **đã duyệt thủ công, chỉ chứa duy nhất 1 khuôn mặt** của người cần lấy. Mỗi lần extract, faceswap dùng folder này làm **ảnh đối chiếu** (positive filter `-f`) → chỉ giữ đúng người đó, bỏ qua mọi mặt khác trong khung hình.

```
workspace/
├── ref_identity/        # FOLDER ĐÃ DUYỆT: 3-10 ảnh, DUY NHẤT 1 người,
│                        #   đa dạng góc mặt + ánh sáng. Curate 1 lần, tái dùng.
├── faces_A/             # output extract (đã được lọc theo ref_identity)
└── src.mp4
```

`convert-faces.sh` đã tích hợp folder này qua biến `REF_DIR`:

```bash
# Build training data: chỉ extract đúng 1 người dựa trên folder reference
FACES_OUT=workspace/faces_A REF_DIR=workspace/ref_A REF_THRESHOLD=0.6 \
  ./convert-faces.sh extract
```

Hoặc gọi trực tiếp faceswap:
```bash
python faceswap.py extract -i <media> -o workspace/faces_A \
  -f workspace/ref_A/ -l 0.6
```

| Flag | Biến script | Tác dụng |
|------|-------------|----------|
| `-f` / `--filter` | `REF_DIR` | Chỉ giữ người trong folder reference |
| `-l` / `--ref_threshold` | `REF_THRESHOLD` | Ngưỡng nhận diện (mặc định `0.60`; cao = chặt hơn) |
| `-n` / `--nfilter` | — | (ngược lại) loại bỏ người không muốn |

> Để trống/không có `REF_DIR` → extract lấy TẤT CẢ mặt (hành vi cũ).

### Cách thay thế: dọn tay sau extract

```bash
python tools.py sort -i workspace/faces_A -o workspace/faces_A_sorted -s face
# -> nhóm theo nhân dạng, mở folder xoá tay mặt thừa
```

### Lưu ý convert

Convert cũng swap MỌI mặt khớp trong frame. Đặt cùng `REF_DIR` → chỉ ghép đúng 1 người (script tự thêm `-f` ở bước convert).

---

## 2. Thuê instance trên vast.ai

| Mục | Khuyến nghị |
|-----|-------------|
| **GPU** | RTX 3090 / 4090 / A5000 (24GB). Tối thiểu RTX 3060 12GB |
| **Image** | `vastai/base-image` tag **CUDA 12.8** — **KHÔNG dùng `vastai/tensorflow`** |
| **Disk** | ≥ 40–60GB |
| **Ports** | 6006 (TensorBoard), 8080 (Jupyter nếu template có) |

**Tại sao base-image, không phải tensorflow image:** project chạy PyTorch, nên TF preinstall là vô dụng và còn dễ gây xung đột CUDA/cuDNN với torch. `base-image` sạch, để script tự cài torch đúng version.

**Khớp CUDA ↔ requirements:**

| Image CUDA | `REQ_FILE` |
|-----------|-----------|
| 12.6.x | `requirements/requirements_nvidia_12.txt` (torch cu126) |
| 12.8 / 13.0 | `requirements/requirements_nvidia_13.txt` (torch cu130) |

> Có template **PyTorch sẵn** (`pytorch/pytorch:2.9-cuda12.8-cudnn9-runtime`)? Dùng `SKIP_TORCH=1` để giữ torch của image.

**Jupyter:** không bắt buộc (train chạy qua CLI). Nếu template có sẵn thì giữ — tiện upload faces và xem ảnh preview. **Không** chạy train trong notebook cell (cell chết khi mất kết nối) — luôn dùng `tmux`.

---

## 3. Setup + train trên instance (qua SSH / Jupyter terminal)

```bash
# Upload script + faces lên instance (scp / rsync / rclone / Jupyter upload)
scp -P <PORT> setup-vast.sh root@<HOST>:~/

# Cài đặt + kiểm tra GPU
REQ_FILE=requirements/requirements_nvidia_13.txt ./setup-vast.sh all
# -> phải thấy "CUDA available: True" trước khi train

# Giải nén faces vào đúng chỗ
tar xzf faces.tar.gz -C ~/faceswap/

# Train trong tmux (sống sót khi mất SSH) + auto-sync lên Google Drive
tmux new -s fs
SYNC_REMOTE="gdrive:faceswap-model" ./setup-vast.sh train
# Ctrl+B rồi D để detach. Gắn lại: tmux attach -t fs
```

**Tinh chỉnh** qua env var:
```bash
TRAINER=villain BATCH_SIZE=8 ./setup-vast.sh train   # giảm batch nếu CUDA OOM
```

Các flag headless mà script dùng sẵn: `-w` (ghi preview ra file, không mở GUI), `-s` (save model), `-I` (snapshot backup). Logs TensorBoard **bật mặc định**.

---

## 4. Theo dõi training

```bash
# Terminal khác trên instance
./setup-vast.sh board          # TensorBoard 0.0.0.0:6006
```
Mở `http://<HOST>:<port-map-cho-6006>` để xem loss giảm theo thời gian.

---

## 5. Auto-sync lên Google Drive

### Config rclone (một lần)

**Trên LOCAL** (có browser):
```bash
brew install rclone
rclone authorize "drive"        # đăng nhập Google -> copy token JSON in ra
```

**Trên INSTANCE**:
```bash
curl https://rclone.org/install.sh | bash
rclone config create gdrive drive config_is_local=false \
  token='{"access_token":"...","refresh_token":"...","expiry":"..."}'
rclone mkdir gdrive:faceswap-model
rclone lsd gdrive:              # test -> liệt kê được là OK
```

### 3 lớp bảo vệ tiến độ (đã tích hợp trong script)

1. **Định kỳ** — sync mỗi `SYNC_INTERVAL` giây (mặc định 1800 = 30 phút)
2. **Khi thoát** — `trap EXIT/INT/TERM` chạy sync lần cuối khi train dừng / Ctrl+C / instance nhận tín hiệu stop
3. **Thủ công** — `./setup-vast.sh sync` đẩy ngay bất cứ lúc nào

```bash
# Giảm rủi ro mất tiến độ nếu instance hay bị kill cứng:
SYNC_REMOTE="gdrive:faceswap-model" SYNC_INTERVAL=600 ./setup-vast.sh train
```

> Lưu ý: kill cứng (SIGKILL/mất điện) thì `trap` không chạy — lúc đó lớp sync định kỳ là phương án dự phòng.

---

## 6. Convert — ghép mặt (LOCAL)

```bash
# Kéo model đã train từ Drive về local
SYNC_REMOTE="gdrive:faceswap-model" MODEL_DIR=workspace/model ./setup-vast.sh pull

# (Tùy chọn) extract faces + alignments cho video NGUỒN cần ghép
INPUT=workspace/src.mp4 ./convert-faces.sh extract

# Ghép mặt -> xuất kết quả
INPUT=workspace/src.mp4 OUTPUT=workspace/converted MODEL_DIR=workspace/model \
  ./convert-faces.sh convert
```

**Tham số chất lượng convert:**

| Biến | Giá trị | Tác dụng |
|------|---------|----------|
| `WRITER` | `ffmpeg` / `opencv` / `pillow` | Định dạng output (ffmpeg = video) |
| `COLOR_ADJ` | `avg-color`, `color-transfer`, `match-hist`, `seamless-clone`, `none` | Khớp màu mặt với nền |
| `MASK_TYPE` | `extended`, `components`, `none`... | Vùng mặt ghép |
| `OUTPUT_SCALE` | `100` | % kích thước so với gốc |

> Convert cần **alignments của video nguồn** (không phải data train). Để trống `ALIGNMENTS` thì faceswap tự dò file cạnh input.
>
> **Frame nhiều mặt?** Đặt `REF_DIR=workspace/ref_A` khi convert → chỉ ghép đúng 1 người (xem mục [Xử lý ảnh nhiều mặt](#xu-ly-anh-nhieu-mat-multi-face)).

---

## Tham chiếu lệnh nhanh

### `setup-vast.sh` (cloud)
| Lệnh | Tác dụng |
|------|----------|
| `install` | Clone repo + pip install deps |
| `check` | Xác nhận torch thấy GPU |
| `train` | Train headless (chạy trong tmux) |
| `board` | TensorBoard port 6006 |
| `sync` | Đẩy model → remote (thủ công) |
| `pull` | Kéo model từ remote → local |
| `all` | install + check |

### `convert-faces.sh` (local)
| Lệnh | Tác dụng |
|------|----------|
| `extract` | Detect faces + tạo alignments cho input (lọc 1 người nếu set `REF_DIR`) |
| `convert` | Áp model đã train lên input → output (lọc 1 người nếu set `REF_DIR`) |

Biến quan trọng: `REF_DIR` (folder reference 1 mặt đã duyệt), `REF_THRESHOLD` (0.60), `FACES_OUT` (thư mục output extract).

---

## Checklist nhanh

- [ ] Extract faces A & B ở local
- [ ] Thuê instance `vastai/base-image` CUDA 12.8 (KHÔNG dùng TF image)
- [ ] `./setup-vast.sh all` → thấy `CUDA available: True`
- [ ] Upload + giải nén faces
- [ ] Config rclone gdrive
- [ ] Train trong `tmux` với `SYNC_REMOTE` đã set
- [ ] Theo dõi loss qua TensorBoard
- [ ] `pull` model về local → `convert` ghép mặt

---

## Câu hỏi chưa giải quyết

- Chưa chốt GPU/model cụ thể → batch size đề xuất (16) mang tính khởi điểm, cần điều chỉnh theo VRAM thực tế (giảm xuống 8/4 nếu OOM).
- Chưa xác định nguồn dữ liệu (ảnh/video) → bước extract có thể cần thêm flag tùy chất lượng nguồn.
