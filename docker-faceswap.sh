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
#                                           #   (add `dedupe=false` to skip dedupe)
#   ./docker-faceswap.sh dedupe             # re-thin an existing faces folder
#   ./docker-faceswap.sh sharp              # report blur / drop blurry faces
#   ./docker-faceswap.sh convert            # apply trained MODEL_DIR -> swapped output
#   ./docker-faceswap.sh shell              # drop into a bash shell in the container
#
# Workspace (WS): all artifacts for one identity live under workspace/<WS>/. WS
# defaults to the input's basename; set it explicitly to train multiple faces.
# Each extract run writes workspace/<WS>/review/<timestamp>/ of deduped faces.
# You review it, delete bad faces, then MOVE keepers into workspace/<WS>/faces/.
#
# Override config via env vars, e.g.:
#   INPUT=my1.mp4 ./docker-faceswap.sh extract                 # WS=my1
#   WS=alice INPUT=alice.mp4 ./docker-faceswap.sh extract       # workspace/alice/
#   WS=alice INPUT=alice.mp4 ./docker-faceswap.sh convert
#
set -euo pipefail

# ============================ CONFIG ============================
FS_DIR="${FS_DIR:-$PWD}"                      # faceswap repo root (mounted into container)
IMAGE="${IMAGE:-faceswap-cpu:local}"          # local image tag (built by `build`)
PLATFORM="${PLATFORM:-linux/amd64}"           # native on Intel Macs; emulated on Apple Silicon

# Source media to extract/convert: a folder of frames OR a single video file.
INPUT="${INPUT:-my1.mp4}"

# --- workspace (one named space per identity, so training many faces never collides) ---
# WS = workspace name. Defaults to the input's basename (my1.mp4 -> "my1").
# ALL artifacts for this identity live under workspace/<WS>/ (ref, review, faces,
# model, converted). Set WS explicitly when training multiple faces, e.g. WS=alice.
WS="${WS:-}"
if [ -z "$WS" ]; then b="$(basename "$INPUT")"; WS="${b%.*}"; fi
WS_DIR="workspace/$WS"

# --- identity filter (multi-face media): curated single-identity folder ---
REF_DIR="${REF_DIR:-$WS_DIR/ref}"             # populate with images of the ONE person to keep/swap
REF_THRESHOLD="${REF_THRESHOLD:-0.60}"        # higher = stricter match

# --- extract quality (balanced high-quality defaults; CPU-friendly) ---
# Defaults chosen for best quality WITHOUT the painfully-slow combos on CPU:
#   retinaface = ~s3fd quality but much faster; hrnet = best aligner AND faster than fan.
# For MAXIMUM quality (slower on CPU): DETECTOR=s3fd MASKER=bisenet-fp
DETECTOR="${DETECTOR:-retinaface}"            # retinaface (best speed/quality) | s3fd (max, slow) | mtcnn | cv2-dnn
ALIGNER="${ALIGNER:-hrnet}"                    # hrnet (best, fully-rotated, fast) | fan | cv2-dnn
MASKER="${MASKER:-}"                           # extra mask (slow): bisenet-fp (refined) | vgg-clear | "" skip
EXTRACT_SIZE="${EXTRACT_SIZE:-512}"           # output face px (model must support this size)
MIN_SIZE="${MIN_SIZE:-0}"                      # drop faces < N% of frame's short side (0=off; ~10 skips tiny)
EXTRACT_NORM="${EXTRACT_NORM:-hist}"          # aligner input normalization: none|hist|clahe|mean (helps lighting)
EXTRACT_EVERY_N="${EXTRACT_EVERY_N:-1}"       # sample every Nth frame (>1 cuts source redundancy + time)

# --- dedupe (thin near-identical faces from slow-motion / consecutive frames) ---
FACES_OUT="${FACES_OUT:-$WS_DIR/faces}"        # standalone `dedupe` input folder
DEDUP_OUT="${DEDUP_OUT:-}"                     # standalone `dedupe` output (default: <FACES_OUT>_dedup)
DEDUP_THRESHOLD="${DEDUP_THRESHOLD:-6}"        # Hamming distance on 64-bit dHash.
                                              #   lower = stricter (drops more); 0 = no dedupe (keep all).
                                              #   ~4-6 thins slow-motion runs; ~10+ very aggressive.

# --- sharpness filter (drop blurry / out-of-focus faces) ---
SHARP_OUT="${SHARP_OUT:-}"                     # standalone `sharp` output (default: <FACES_OUT>_sharp)
BLUR_THRESHOLD="${BLUR_THRESHOLD:-0}"          # min Laplacian variance; faces below = blurry, dropped.
                                              #   0 = REPORT mode (print distribution, copy nothing).
                                              #   typical face crops: <50 very blurry, 100-300 ok, >300 sharp.

# --- extract review flow: extract -> dedupe -> timestamped folder for manual review ---
# Each `extract` run writes a fresh timestamped folder under REVIEW_DIR. You curate
# it (delete bad faces) then MOVE the approved faces into the folder convert/train
# needs. Nothing is overwritten between runs.
REVIEW_DIR="${REVIEW_DIR:-$WS_DIR/review}"     # parent folder for timestamped review runs
KEEP_RAW="${KEEP_RAW:-0}"                      # 1 = also keep the pre-dedupe raw faces (in <run>_raw)
DEDUP="${DEDUP:-true}"                          # extract dedupes by default; disable with `dedupe=false`

# --- convert ---
OUTPUT="${OUTPUT:-$WS_DIR/converted}"         # final swapped frames/video
MODEL_DIR="${MODEL_DIR:-$WS_DIR/model}"       # trained model dir (pull from cloud first)
ALIGNMENTS="${ALIGNMENTS:-}"                  # empty = let faceswap auto-detect
ALIGNED_DIR="${ALIGNED_DIR:-}"               # optional pre-extracted aligned faces dir
WRITER="${WRITER:-ffmpeg}"                    # ffmpeg (video) | opencv | pillow
COLOR_ADJ="${COLOR_ADJ:-avg-color}"           # avg-color | color-transfer | match-hist | none
MASK_TYPE="${MASK_TYPE:-extended}"            # extended | components | none | <trained>
OUTPUT_SCALE="${OUTPUT_SCALE:-100}"           # output size percent
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

# Run faceswap extract for INPUT into a given output dir (repo-relative), using
# the configured best-quality plugins (detector/aligner/masker/size/normalization).
extract_to() {
  local out="$1"
  mkdir -p "$FS_DIR/$out"
  local args=( extract -i "$INPUT" -o "$out"
               -D "$DETECTOR" -A "$ALIGNER" -z "$EXTRACT_SIZE" -O "$EXTRACT_NORM" )
  [ -n "$MASKER" ]            && args+=( -M "$MASKER" )
  [ "$MIN_SIZE" -gt 0 ]       && args+=( -m "$MIN_SIZE" )
  [ "$EXTRACT_EVERY_N" -gt 1 ] && args+=( -N "$EXTRACT_EVERY_N" )
  if [ -n "$REF_DIR" ] && [ -d "$FS_DIR/$REF_DIR" ]; then
    args+=( -f "$REF_DIR" -l "$REF_THRESHOLD" )
    log "Identity filter ON -> ref=$REF_DIR threshold=$REF_THRESHOLD (single face only)"
  else
    log "Identity filter OFF -> extracting ALL detected faces (REF_DIR empty/missing)"
  fi
  log "Extracting: $INPUT -> $out  (detector=$DETECTOR aligner=$ALIGNER mask=${MASKER:-none} size=$EXTRACT_SIZE norm=$EXTRACT_NORM)"
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
  log "Workspace: '$WS' -> $WS_DIR/  (ref=$REF_DIR review=$REVIEW_DIR)"

  # Inline toggle: `extract dedupe=false` disables dedupe for this run.
  local arg
  for arg in "$@"; do
    case "$arg" in
      dedupe=false|dedupe=no|dedupe=0)  DEDUP=false ;;
      dedupe=true|dedupe=yes|dedupe=1)  DEDUP=true ;;
      *) err "Unknown extract option: $arg (use dedupe=true|false)"; exit 1 ;;
    esac
  done

  local stamp run raw
  stamp="$(date +%Y%m%d-%H%M%S)"
  run="$REVIEW_DIR/$stamp"                      # final reviewed faces land here
  raw="${run}_raw"                              # pre-dedupe extract output

  extract_to "$raw"

  # Dedupe by default; skip if dedupe=false OR DEDUP_THRESHOLD=0.
  if [ "$DEDUP" = "true" ] && [ "$DEDUP_THRESHOLD" -gt 0 ]; then
    log "Deduping into review folder (threshold=$DEDUP_THRESHOLD bits)"
    dedupe_dir "$raw" "$run" "$DEDUP_THRESHOLD"
    if [ "$KEEP_RAW" = "1" ]; then
      log "KEEP_RAW=1 -> raw faces kept at $raw"
    else
      rm -rf "$FS_DIR/$raw"
    fi
  else
    log "Dedupe OFF (dedupe=false or DEDUP_THRESHOLD=0) -> keeping all faces"
    mv "$FS_DIR/$raw" "$FS_DIR/$run"
  fi

  # Optional in-flow sharpness filter: drop blurry faces when BLUR_THRESHOLD>0.
  if [ "$BLUR_THRESHOLD" -gt 0 ]; then
    log "Sharpness filter into review folder (drop variance < $BLUR_THRESHOLD)"
    local pre="${run}_blurry"
    mv "$FS_DIR/$run" "$FS_DIR/$pre"
    blur_filter "$pre" "$run" "$BLUR_THRESHOLD"
    [ "$KEEP_RAW" = "1" ] && log "KEEP_RAW=1 -> blurry faces kept at $pre" || rm -rf "$FS_DIR/$pre"
  else
    log "Sharpness filter OFF (BLUR_THRESHOLD=0). Tip: '$0 sharp' to report blur, then set BLUR_THRESHOLD."
  fi

  local n; n="$(ls "$FS_DIR/$run" 2>/dev/null | wc -l | tr -d ' ')"
  log "Review folder ready -> $run ($n faces)"
  log "NEXT: review $run, delete bad faces, then MOVE the keepers into:"
  log "      $WS_DIR/faces/   (upload that as faces_A/B for training, or use as ALIGNED_DIR)"
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

# Sharpness filter: drop blurry faces by Laplacian variance (cv2). THRESH<=0 =
# REPORT only (print blur distribution, copy nothing) so you can pick a value.
# Shared by `extract` (in-flow) and the standalone `sharp` command (DRY).
blur_filter() {
  local src="$1" out="$2" thresh="$3"
  [ "$thresh" -gt 0 ] && mkdir -p "$FS_DIR/$out"
  docker run --rm -i --platform "$PLATFORM" \
    -v "$FS_DIR":/fs -w /fs \
    -e SRC="$src" -e OUT="$out" -e THRESH="$thresh" \
    "$IMAGE" python - <<'PY'
import os, shutil
import cv2

src, out, thresh = os.environ["SRC"], os.environ["OUT"], float(os.environ["THRESH"])
files = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))

def sharpness(path):
    # Variance of the Laplacian: low = blurry / out of focus, high = crisp edges.
    g = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    return float(cv2.Laplacian(g, cv2.CV_64F).var())

vals = [(f, sharpness(os.path.join(src, f))) for f in files]
vs = sorted(v for _, v in vals)
pct = lambda p: vs[min(len(vs) - 1, int(p * len(vs)))] if vs else 0.0
print(f"Blur (Laplacian variance) over {len(vals)} faces:")
print(f"  min={vs[0]:.0f}  p10={pct(.10):.0f}  p25={pct(.25):.0f}  "
      f"median={pct(.50):.0f}  p75={pct(.75):.0f}  max={vs[-1]:.0f}")

if thresh > 0:
    kept = 0
    for f, v in vals:
        if v >= thresh:
            shutil.copy2(os.path.join(src, f), os.path.join(out, f)); kept += 1
    print(f"threshold={thresh:.0f} -> kept {kept}, dropped {len(vals) - kept} -> {out}")
else:
    print("REPORT only (BLUR_THRESHOLD=0). Pick ~p10-p25 then re-run with BLUR_THRESHOLD=<n>.")
PY
}

# Standalone sharpness filter / report on an existing faces folder (FACES_OUT).
cmd_sharp() {
  ensure_image
  local src="$FACES_OUT" out="${SHARP_OUT:-${FACES_OUT}_sharp}"
  [ -d "$FS_DIR/$src" ] || { err "FACES_OUT not found: $src (run extract first)"; exit 1; }
  if [ "$BLUR_THRESHOLD" -gt 0 ]; then
    log "Sharpness filter: $src -> $out (drop variance < $BLUR_THRESHOLD)"
  else
    log "Sharpness REPORT: $src (set BLUR_THRESHOLD=<n> to actually filter)"
  fi
  blur_filter "$src" "$out" "$BLUR_THRESHOLD"
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
  extract) cmd_extract "${@:2}" ;;
  dedupe)  cmd_dedupe ;;
  sharp)   cmd_sharp ;;
  convert) cmd_convert ;;
  shell)   cmd_shell ;;
  *)
    cat <<EOF
Usage: $0 {build|extract|dedupe|sharp|convert|shell}

  build    Build the CPU image once (bakes deps; runs are instant afterwards)
  extract  Best-quality detect (s3fd+hrnet+bisenet-fp) -> dedupe -> optional blur
           filter -> fresh TIMESTAMPED folder under REVIEW_DIR. Curate it, then
           MOVE keepers to workspace/<WS>/faces/. Disable dedupe: extract dedupe=false
  dedupe   Standalone: re-thin an existing FACES_OUT folder -> DEDUP_OUT
  sharp    Report blur distribution of FACES_OUT (or filter if BLUR_THRESHOLD>0)
  convert  Apply trained MODEL_DIR onto INPUT -> OUTPUT (the face swap)
  shell    Open a bash shell inside the container (debugging)

Why Docker: Intel Macs have NO torchvision>=0.18 wheel, so faceswap can't run
natively. This runs the linux/amd64 CPU build instead. (Train -> use setup-vast.sh.)

Workspace (WS): all artifacts for one identity live under workspace/<WS>/ (ref,
review, faces, model, converted). WS defaults to the input's basename. Set WS
explicitly to train multiple faces without collision:
  workspace/<WS>/ref/      <- your reference images (single identity)
  workspace/<WS>/review/   <- timestamped extract+dedupe runs (curate these)
  workspace/<WS>/faces/    <- move approved faces here (train data / ALIGNED_DIR)
  workspace/<WS>/model/    <- trained model (pull from cloud)
  workspace/<WS>/converted/<- convert output

Quality knobs (extract): DETECTOR=s3fd ALIGNER=hrnet MASKER=bisenet-fp
EXTRACT_SIZE=512 EXTRACT_NORM=hist MIN_SIZE (skip tiny faces) EXTRACT_EVERY_N.
Blur: run '$0 sharp' to see the distribution, then BLUR_THRESHOLD=<n> to drop blurry.

Examples:
  INPUT=my1.mp4 $0 extract                  # WS=my1 -> workspace/my1/review/<ts>/
  WS=alice INPUT=alice.mp4 $0 extract       # all under workspace/alice/
  INPUT=my1.mp4 $0 extract dedupe=false     # skip dedupe (keep all faces)
  WS=alice MIN_SIZE=10 BLUR_THRESHOLD=100 INPUT=alice.mp4 $0 extract  # strict quality
  FACES_OUT=workspace/alice/faces $0 sharp                  # report blur distribution
  FACES_OUT=workspace/alice/faces BLUR_THRESHOLD=100 $0 sharp  # drop blurry
  WS=alice INPUT=alice.mp4 $0 convert       # uses workspace/alice/model + /converted
EOF
    exit 1 ;;
esac
