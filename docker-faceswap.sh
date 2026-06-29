#!/usr/bin/env bash
#
# docker-faceswap.sh — Run faceswap extract/convert inside a Linux CPU container.
#
# WHY: PyTorch dropped macOS x86_64 (Intel Mac) wheels; faceswap needs
# torchvision>=0.18 which has NO Intel-Mac wheel. So extract/convert cannot run
# natively on Intel macOS. This wraps them in a linux/amd64 container (runs
# native on Intel Macs, emulated on Apple Silicon) where CPU wheels exist.
#
# Train still belongs on a real GPU (vast.ai) — see setup-vast.sh. This script
# is the LOCAL extract + convert counterpart of convert-faces.sh, dockerized.
#
# USAGE:
#   ./docker-faceswap.sh build              # build the CPU image once (bakes deps)
#   ./docker-faceswap.sh extract            # detect faces + alignments from INPUT
#   ./docker-faceswap.sh convert            # apply trained MODEL_DIR -> swapped output
#   ./docker-faceswap.sh shell              # drop into a bash shell in the container
#
# Override config via env vars, e.g.:
#   INPUT=my1.mp4 FACES_OUT=workspace/faces_my1 ./docker-faceswap.sh extract
#   INPUT=src.mp4 OUTPUT=workspace/out MODEL_DIR=workspace/model ./docker-faceswap.sh convert
#   REF_DIR=workspace/ref_A REF_THRESHOLD=0.6 ./docker-faceswap.sh extract
#
set -euo pipefail

# ============================ CONFIG ============================
FS_DIR="${FS_DIR:-$PWD}"                      # faceswap repo root (mounted into container)
IMAGE="${IMAGE:-faceswap-cpu:local}"          # local image tag (built by `build`)
PLATFORM="${PLATFORM:-linux/amd64}"           # native on Intel Macs; emulated on Apple Silicon

# Source media to extract/convert: a folder of frames OR a single video file.
INPUT="${INPUT:-my1.mp4}"

# --- extract ---
FACES_OUT="${FACES_OUT:-workspace/faces_my1}" # where extracted faces are written

# --- dedupe (thin near-identical faces from slow-motion / consecutive frames) ---
DEDUP_OUT="${DEDUP_OUT:-}"                     # output dir (default: <FACES_OUT>_dedup)
DEDUP_THRESHOLD="${DEDUP_THRESHOLD:-6}"        # Hamming distance on 64-bit dHash.
                                              #   lower = stricter (drops more); 0 = exact dupes only.
                                              #   ~4-6 thins slow-motion runs; ~10+ very aggressive.

# --- convert ---
OUTPUT="${OUTPUT:-workspace/converted}"       # final swapped frames/video
MODEL_DIR="${MODEL_DIR:-workspace/model}"     # trained model dir (pull from cloud first)
ALIGNMENTS="${ALIGNMENTS:-}"                  # empty = let faceswap auto-detect
ALIGNED_DIR="${ALIGNED_DIR:-}"               # optional pre-extracted aligned faces dir
WRITER="${WRITER:-ffmpeg}"                    # ffmpeg (video) | opencv | pillow
COLOR_ADJ="${COLOR_ADJ:-avg-color}"           # avg-color | color-transfer | match-hist | none
MASK_TYPE="${MASK_TYPE:-extended}"            # extended | components | none | <trained>
OUTPUT_SCALE="${OUTPUT_SCALE:-100}"           # output size percent

# --- identity filter (multi-face media): curated single-identity folder ---
REF_DIR="${REF_DIR:-workspace/ref_identity}"  # set & populate to keep/swap ONE person only
REF_THRESHOLD="${REF_THRESHOLD:-0.60}"        # higher = stricter match
# ===============================================================

log() { printf '\033[1;34m[docker-fs]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[docker-fs]\033[0m %s\n' "$*" >&2; }

# Build the CPU image with all deps baked in (fast, cached). Only requirements
# are copied at build time so the layer cache survives source edits.
cmd_build() {
  log "Building $IMAGE ($PLATFORM) — deps baked in, runs are instant afterwards"
  DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" -t "$IMAGE" -f - "$FS_DIR" <<'DOCKERFILE'
FROM python:3.12-slim
ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1
# tk: faceswap imports tkinter even for CLI (lib/utils.py) -> needs libtk runtime.
# libgl1/libglib: OpenCV.  ffmpeg: video writer.
RUN apt-get update -qq \
 && apt-get install -y -qq libgl1 libglib2.0-0 ffmpeg tk \
 && rm -rf /var/lib/apt/lists/*
# Copy only requirements first so edits to source code don't bust this layer.
COPY requirements/ /tmp/requirements/
RUN pip install -r /tmp/requirements/requirements_cpu.txt
WORKDIR /fs
DOCKERFILE
  log "Build complete: $IMAGE"
}

# Ensure the image exists before running.
ensure_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || { log "Image $IMAGE missing -> building"; cmd_build; }
}

# Run faceswap inside the container with the repo mounted and plugin weights
# cached in a named volume (persist across runs). Args after the func name are
# passed straight to faceswap.py.
run_fs() {
  ensure_image
  docker run --rm --platform "$PLATFORM" \
    -v "$FS_DIR":/fs -w /fs \
    -v faceswap-fs-cache:/fs/.fs_cache \
    "$IMAGE" python faceswap.py "$@"
}

cmd_extract() {
  [ -e "$FS_DIR/$INPUT" ] || { err "INPUT not found: $INPUT (relative to $FS_DIR)"; exit 1; }
  mkdir -p "$FS_DIR/$FACES_OUT"
  local args=( extract -i "$INPUT" -o "$FACES_OUT" )
  if [ -n "$REF_DIR" ] && [ -d "$FS_DIR/$REF_DIR" ]; then
    args+=( -f "$REF_DIR" -l "$REF_THRESHOLD" )
    log "Identity filter ON -> ref=$REF_DIR threshold=$REF_THRESHOLD (single face only)"
  else
    log "Identity filter OFF -> extracting ALL detected faces (REF_DIR empty/missing)"
  fi
  log "Extracting: $INPUT -> $FACES_OUT"
  run_fs "${args[@]}"
  log "Extract done -> $FACES_OUT ($(ls "$FS_DIR/$FACES_OUT" 2>/dev/null | wc -l | tr -d ' ') files)"
}

cmd_convert() {
  [ -e "$FS_DIR/$INPUT" ]     || { err "INPUT not found: $INPUT"; exit 1; }
  [ -d "$FS_DIR/$MODEL_DIR" ] || { err "MODEL_DIR not found: $MODEL_DIR (pull it from the cloud first)"; exit 1; }
  mkdir -p "$FS_DIR/$OUTPUT"
  local args=( convert -i "$INPUT" -o "$OUTPUT" -m "$MODEL_DIR"
               -w "$WRITER" -c "$COLOR_ADJ" -M "$MASK_TYPE" -O "$OUTPUT_SCALE" )
  [ -n "$ALIGNMENTS" ]  && args+=( -p "$ALIGNMENTS" )
  [ -n "$ALIGNED_DIR" ] && args+=( -a "$ALIGNED_DIR" )
  if [ -n "$REF_DIR" ] && [ -d "$FS_DIR/$REF_DIR" ]; then
    args+=( -f "$REF_DIR" -l "$REF_THRESHOLD" )
    log "Identity filter ON -> ref=$REF_DIR threshold=$REF_THRESHOLD (swap single face only)"
  fi
  log "Converting: $INPUT -> $OUTPUT (model=$MODEL_DIR writer=$WRITER mask=$MASK_TYPE)"
  run_fs "${args[@]}"
  log "Convert complete -> $OUTPUT"
}

# Remove near-identical faces (slow-motion -> consecutive frames look the same).
# Uses a 64-bit dHash; keeps an image only if it differs from every already-kept
# image by >= DEDUP_THRESHOLD bits. Face PNGs carry their alignment metadata, so
# the thinned folder is directly usable for training. Pure PIL+numpy (in image).
cmd_dedupe() {
  ensure_image
  local src="$FACES_OUT" out="${DEDUP_OUT:-${FACES_OUT}_dedup}"
  [ -d "$FS_DIR/$src" ] || { err "FACES_OUT not found: $src (run extract first)"; exit 1; }
  mkdir -p "$FS_DIR/$out"
  log "Deduping: $src -> $out (threshold=$DEDUP_THRESHOLD bits)"
  docker run --rm -i --platform "$PLATFORM" \
    -v "$FS_DIR":/fs -w /fs \
    -e SRC="$src" -e OUT="$out" -e THRESH="$DEDUP_THRESHOLD" \
    "$IMAGE" python - <<'PY'
import os, shutil
import numpy as np
from PIL import Image

src, out, thresh = os.environ["SRC"], os.environ["OUT"], int(os.environ["THRESH"])
files = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))

def dhash(path, size=8):
    # 9x8 grayscale -> 64-bit row-wise gradient hash (robust to tiny shifts/noise).
    img = Image.open(path).convert("L").resize((size + 1, size))
    a = np.asarray(img, dtype=np.int16)
    bits = a[:, 1:] > a[:, :-1]
    return np.packbits(bits.flatten())

kept_hashes, kept = [], 0
for i, f in enumerate(files, 1):
    h = dhash(os.path.join(src, f))
    if kept_hashes:
        dists = [int(np.unpackbits(h ^ kh).sum()) for kh in kept_hashes]
        if min(dists) < thresh:
            continue  # too similar to something already kept -> drop
    kept_hashes.append(h)
    shutil.copy2(os.path.join(src, f), os.path.join(out, f))
    kept += 1

print(f"Scanned {len(files)} faces -> kept {kept}, dropped {len(files) - kept} "
      f"(threshold {thresh} bits) -> {out}")
PY
  log "Dedupe done -> $out ($(ls "$FS_DIR/$out" 2>/dev/null | wc -l | tr -d ' ') files)"
}

cmd_shell() {
  ensure_image
  docker run --rm -it --platform "$PLATFORM" \
    -v "$FS_DIR":/fs -w /fs \
    -v faceswap-fs-cache:/fs/.fs_cache \
    "$IMAGE" bash
}

case "${1:-}" in
  build)   cmd_build ;;
  extract) cmd_extract ;;
  dedupe)  cmd_dedupe ;;
  convert) cmd_convert ;;
  shell)   cmd_shell ;;
  *)
    cat <<EOF
Usage: $0 {build|extract|dedupe|convert|shell}

  build    Build the CPU image once (bakes deps; runs are instant afterwards)
  extract  Detect faces + alignments from INPUT -> FACES_OUT
  dedupe   Drop near-identical faces (slow-motion frames) FACES_OUT -> *_dedup
  convert  Apply trained MODEL_DIR onto INPUT -> OUTPUT (the face swap)
  shell    Open a bash shell inside the container (debugging)

Why Docker: Intel Macs have NO torchvision>=0.18 wheel, so faceswap can't run
natively. This runs the linux/amd64 CPU build instead. (Train -> use setup-vast.sh.)

Examples:
  INPUT=my1.mp4 FACES_OUT=workspace/faces_my1 $0 extract
  FACES_OUT=workspace/faces_my1 DEDUP_THRESHOLD=6 $0 dedupe   # thin look-alike frames
  REF_DIR=workspace/ref_A REF_THRESHOLD=0.6 FACES_OUT=workspace/faces_A $0 extract
  INPUT=src.mp4 OUTPUT=workspace/out MODEL_DIR=workspace/model $0 convert
EOF
    exit 1 ;;
esac
