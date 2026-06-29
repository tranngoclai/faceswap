#!/usr/bin/env bash
#
# convert-faces.sh — Headless face-swap conversion for deepfakes/faceswap.
#
# Runs the `faceswap.py convert` step: applies a TRAINED model onto source
# frames/video, producing the final swapped output. Convert is light on GPU,
# so this is typically run LOCALLY after pulling the model from the cloud.
#
# PREREQUISITES (the normal faceswap pipeline order):
#   1) extract  -> detect faces in the source media + build an `alignments` file
#   2) train    -> done on vast.ai (use setup-vast.sh)
#   3) convert  -> THIS script (needs the source media + its alignments + model)
#
# USAGE:
#   ./convert-faces.sh extract     # (optional) extract faces + alignments from source
#   ./convert-faces.sh convert     # produce the swapped output
#
# Edit the CONFIG block, or override via env vars:
#   INPUT=workspace/src.mp4 OUTPUT=workspace/out MODEL_DIR=workspace/model ./convert-faces.sh convert
#
set -euo pipefail

# ============================ CONFIG ============================
FS_DIR="${FS_DIR:-$PWD}"                      # faceswap repo root (run from repo by default)

# Source media to convert: a folder of frames OR a single video file.
INPUT="${INPUT:-workspace/src.mp4}"

# Where the final swapped frames/video are written.
OUTPUT="${OUTPUT:-workspace/converted}"

# Trained model directory (the same -m used during training).
MODEL_DIR="${MODEL_DIR:-workspace/model}"

# Alignments file for the SOURCE media (produced by the extract step).
# Default location faceswap uses sits next to the input. Leave empty to let
# faceswap auto-detect (input_dir/alignments.fsa or <video>_alignments.fsa).
ALIGNMENTS="${ALIGNMENTS:-}"

# Optional: pre-extracted aligned faces dir to skip on-the-fly alignment (faster,
# and lets you curate which faces get swapped). Leave empty to convert all.
ALIGNED_DIR="${ALIGNED_DIR:-}"

# --- Identity filter (handle media with MULTIPLE faces) -------------------------
# REF_DIR: a curated/approved folder holding images of the ONE identity you want.
#   Used as faceswap's positive filter (-f) on BOTH extract and convert, so every
#   run only keeps/swaps that single person and ignores everyone else in frame.
#   Put a small, varied set (different angles + lighting) of that person here.
#   Leave empty to disable filtering (keeps ALL detected faces — old behavior).
REF_DIR="${REF_DIR:-workspace/ref_identity}"

# Face-recognition threshold for REF_DIR matching (0.01-0.99). Higher = stricter.
REF_THRESHOLD="${REF_THRESHOLD:-0.60}"

# Where extracted faces are written (review folder). Override to extract training data.
FACES_OUT="${FACES_OUT:-workspace/src_faces}"

# Output writer: ffmpeg (video) | opencv | pillow (image sequence).
# Use ffmpeg if INPUT is a video and you want a video out.
WRITER="${WRITER:-ffmpeg}"

# Color adjustment: avg-color | color-transfer | match-hist | seamless-clone | none
COLOR_ADJ="${COLOR_ADJ:-avg-color}"

# Mask type applied at convert time: extended | components | none | <trained mask> ...
MASK_TYPE="${MASK_TYPE:-extended}"

# Output scale (percent). 100 = same size as source.
OUTPUT_SCALE="${OUTPUT_SCALE:-100}"
# ===============================================================

log() { printf '\033[1;36m[convert]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[convert]\033[0m %s\n' "$*" >&2; }

abspath() { case "$1" in /*) echo "$1";; *) echo "$FS_DIR/$1";; esac; }

# Step 1 (optional): detect faces in the source and build the alignments file.
cmd_extract() {
  cd "$FS_DIR"
  local in out
  in="$(abspath "$INPUT")"
  out="$(abspath "$FACES_OUT")"            # extracted faces (for review/curation)
  [ -e "$in" ] || { err "INPUT not found: $in"; exit 1; }
  mkdir -p "$out"

  local args=( -i "$in" -o "$out" )
  # If a curated reference folder exists, only keep that ONE identity (-f filter).
  if [ -n "$REF_DIR" ] && [ -d "$(abspath "$REF_DIR")" ]; then
    args+=( -f "$(abspath "$REF_DIR")" -l "$REF_THRESHOLD" )
    log "Identity filter ON -> ref=$REF_DIR threshold=$REF_THRESHOLD (single face only)"
  else
    log "Identity filter OFF -> extracting ALL detected faces (REF_DIR empty/missing)"
  fi

  log "Extracting faces + alignments from: $in"
  python faceswap.py extract "${args[@]}"
  log "Extract done. alignments file written next to the input."
}

# Step 3: run the actual face swap.
cmd_convert() {
  cd "$FS_DIR"
  local in out m
  in="$(abspath "$INPUT")"
  out="$(abspath "$OUTPUT")"
  m="$(abspath "$MODEL_DIR")"

  [ -e "$in" ]         || { err "INPUT not found: $in"; exit 1; }
  [ -d "$m" ]          || { err "MODEL_DIR not found: $m (pull it from the cloud first)"; exit 1; }
  mkdir -p "$out"

  # Build args; only pass optional flags when set so faceswap can auto-detect.
  local args=( -i "$in" -o "$out" -m "$m"
               -w "$WRITER" -c "$COLOR_ADJ" -M "$MASK_TYPE" -O "$OUTPUT_SCALE" )
  [ -n "$ALIGNMENTS" ] && args+=( -p "$(abspath "$ALIGNMENTS")" )
  [ -n "$ALIGNED_DIR" ] && args+=( -a "$(abspath "$ALIGNED_DIR")" )
  # Same curated reference -> only swap that ONE identity, ignore other faces in frame.
  if [ -n "$REF_DIR" ] && [ -d "$(abspath "$REF_DIR")" ]; then
    args+=( -f "$(abspath "$REF_DIR")" -l "$REF_THRESHOLD" )
    log "Identity filter ON -> ref=$REF_DIR threshold=$REF_THRESHOLD (swap single face only)"
  fi

  log "Converting: writer=$WRITER color=$COLOR_ADJ mask=$MASK_TYPE scale=${OUTPUT_SCALE}%"
  log "  input : $in"
  log "  model : $m"
  log "  output: $out"
  python faceswap.py convert "${args[@]}"
  log "Convert complete -> $out"
}

case "${1:-}" in
  extract) cmd_extract ;;
  convert) cmd_convert ;;
  *)
    cat <<EOF
Usage: $0 {extract|convert}

  extract  (optional) Detect faces in INPUT + build alignments file
  convert  Apply trained MODEL_DIR onto INPUT -> OUTPUT (the face swap)

Multiple faces in frame? Put a curated set of the ONE person into REF_DIR
(default workspace/ref_identity). Both extract & convert then keep/swap only
that identity. Empty/missing REF_DIR = process ALL faces (old behavior).

Override config via env vars, e.g.:
  INPUT=workspace/src.mp4 OUTPUT=workspace/out MODEL_DIR=workspace/model $0 convert
  REF_DIR=workspace/ref_A REF_THRESHOLD=0.6 $0 extract
  FACES_OUT=workspace/faces_A REF_DIR=workspace/ref_A $0 extract   # build training data
  WRITER=opencv COLOR_ADJ=color-transfer MASK_TYPE=extended $0 convert
EOF
    exit 1 ;;
esac
