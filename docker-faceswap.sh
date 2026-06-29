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
#   ./docker-faceswap.sh extract            # extract -> dedupe -> timestamped review folder
#   ./docker-faceswap.sh dedupe             # re-thin an existing faces folder
#   ./docker-faceswap.sh convert            # apply trained MODEL_DIR -> swapped output
#   ./docker-faceswap.sh shell              # drop into a bash shell in the container
#
# Extract flow: each run writes a fresh workspace/review/<timestamp>/ of deduped
# faces. You review it, delete bad faces, then MOVE the keepers into the folder
# convert/train needs. Runs never overwrite each other.
#
# Override config via env vars, e.g.:
#   INPUT=my1.mp4 ./docker-faceswap.sh extract
#   INPUT=my1.mp4 DEDUP_THRESHOLD=4 REF_DIR=workspace/ref_A ./docker-faceswap.sh extract
#   INPUT=src.mp4 OUTPUT=workspace/out MODEL_DIR=workspace/model ./docker-faceswap.sh convert
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
DEDUP_OUT="${DEDUP_OUT:-}"                     # standalone `dedupe` output (default: <FACES_OUT>_dedup)
DEDUP_THRESHOLD="${DEDUP_THRESHOLD:-6}"        # Hamming distance on 64-bit dHash.
                                              #   lower = stricter (drops more); 0 = no dedupe (keep all).
                                              #   ~4-6 thins slow-motion runs; ~10+ very aggressive.

# --- extract review flow: extract -> dedupe -> timestamped folder for manual review ---
# Each `extract` run writes a fresh timestamped folder under REVIEW_DIR. You curate
# it (delete bad faces) then MOVE the approved faces into the folder convert/train
# needs. Nothing is overwritten between runs.
REVIEW_DIR="${REVIEW_DIR:-workspace/review}"  # parent folder for timestamped review runs
KEEP_RAW="${KEEP_RAW:-0}"                      # 1 = also keep the pre-dedupe raw faces (in <run>_raw)

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

# Run faceswap extract for INPUT into a given output dir (repo-relative).
extract_to() {
  local out="$1"
  mkdir -p "$FS_DIR/$out"
  local args=( extract -i "$INPUT" -o "$out" )
  if [ -n "$REF_DIR" ] && [ -d "$FS_DIR/$REF_DIR" ]; then
    args+=( -f "$REF_DIR" -l "$REF_THRESHOLD" )
    log "Identity filter ON -> ref=$REF_DIR threshold=$REF_THRESHOLD (single face only)"
  else
    log "Identity filter OFF -> extracting ALL detected faces (REF_DIR empty/missing)"
  fi
  log "Extracting: $INPUT -> $out"
  run_fs "${args[@]}"
}

# Dedupe SRC -> OUT (repo-relative) at THRESH Hamming bits. THRESH<=0 = copy all.
# Shared by `extract` (in-flow) and the standalone `dedupe` command (DRY).
dedupe_dir() {
  local src="$1" out="$2" thresh="$3"
  mkdir -p "$FS_DIR/$out"
  docker run --rm -i --platform "$PLATFORM" \
    -v "$FS_DIR":/fs -w /fs \
    -e SRC="$src" -e OUT="$out" -e THRESH="$thresh" \
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
for f in files:
    if thresh > 0 and kept_hashes:
        h = dhash(os.path.join(src, f))
        if min(int(np.unpackbits(h ^ kh).sum()) for kh in kept_hashes) < thresh:
            continue  # too similar to something already kept -> drop
        kept_hashes.append(h)
    elif thresh > 0:
        kept_hashes.append(dhash(os.path.join(src, f)))
    shutil.copy2(os.path.join(src, f), os.path.join(out, f))
    kept += 1

print(f"Scanned {len(files)} faces -> kept {kept}, dropped {len(files) - kept} "
      f"(threshold {thresh} bits) -> {out}")
PY
}

# extract -> dedupe -> fresh TIMESTAMPED review folder. You curate it, then move
# the approved faces into the folder convert/train needs. Runs never overwrite.
cmd_extract() {
  ensure_image
  [ -e "$FS_DIR/$INPUT" ] || { err "INPUT not found: $INPUT (relative to $FS_DIR)"; exit 1; }
  local stamp run raw
  stamp="$(date +%Y%m%d-%H%M%S)"
  run="$REVIEW_DIR/$stamp"                      # final reviewed faces land here
  raw="${run}_raw"                              # pre-dedupe extract output

  extract_to "$raw"

  if [ "$DEDUP_THRESHOLD" -gt 0 ]; then
    log "Deduping into review folder (threshold=$DEDUP_THRESHOLD bits)"
    dedupe_dir "$raw" "$run" "$DEDUP_THRESHOLD"
    if [ "$KEEP_RAW" = "1" ]; then
      log "KEEP_RAW=1 -> raw faces kept at $raw"
    else
      rm -rf "$FS_DIR/$raw"
    fi
  else
    log "DEDUP_THRESHOLD=0 -> skipping dedupe (keeping all faces)"
    mv "$FS_DIR/$raw" "$FS_DIR/$run"
  fi

  local n; n="$(ls "$FS_DIR/$run" 2>/dev/null | wc -l | tr -d ' ')"
  log "Review folder ready -> $run ($n faces)"
  log "NEXT: review $run, delete bad faces, then MOVE the keepers into the folder"
  log "      your convert/train step uses (e.g. ALIGNED_DIR or faces_A)."
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

# Standalone dedupe of an existing faces folder (FACES_OUT) -> DEDUP_OUT.
# `extract` already dedupes in-flow; use this to re-thin an arbitrary folder.
cmd_dedupe() {
  ensure_image
  local src="$FACES_OUT" out="${DEDUP_OUT:-${FACES_OUT}_dedup}"
  [ -d "$FS_DIR/$src" ] || { err "FACES_OUT not found: $src (run extract first)"; exit 1; }
  log "Deduping: $src -> $out (threshold=$DEDUP_THRESHOLD bits)"
  dedupe_dir "$src" "$out" "$DEDUP_THRESHOLD"
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
  extract  Detect faces -> dedupe -> fresh TIMESTAMPED folder under REVIEW_DIR.
           You then curate it and MOVE the keepers where convert/train needs.
  dedupe   Standalone: re-thin an existing FACES_OUT folder -> DEDUP_OUT
  convert  Apply trained MODEL_DIR onto INPUT -> OUTPUT (the face swap)
  shell    Open a bash shell inside the container (debugging)

Why Docker: Intel Macs have NO torchvision>=0.18 wheel, so faceswap can't run
natively. This runs the linux/amd64 CPU build instead. (Train -> use setup-vast.sh.)

Extract flow: each run writes workspace/review/<timestamp>/ (deduped). Review it,
delete bad faces, then move the approved faces into your target folder. Tune with
DEDUP_THRESHOLD (0 = no dedupe), KEEP_RAW=1 to also keep pre-dedupe faces.

Examples:
  INPUT=my1.mp4 $0 extract                       # -> workspace/review/<timestamp>/
  INPUT=my1.mp4 DEDUP_THRESHOLD=4 $0 extract     # keep more (lighter dedupe)
  INPUT=my1.mp4 REF_DIR=workspace/ref_A $0 extract   # single-identity only
  REVIEW_DIR=workspace/review_B INPUT=b.mp4 $0 extract
  FACES_OUT=workspace/faces_my1 DEDUP_THRESHOLD=6 $0 dedupe   # re-thin a folder
  INPUT=src.mp4 OUTPUT=workspace/out MODEL_DIR=workspace/model $0 convert
EOF
    exit 1 ;;
esac
