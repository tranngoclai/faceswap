#!/usr/bin/env bash
#
# setup-vast.sh — One-shot setup + headless training for deepfakes/faceswap on vast.ai
#
# Backend: PyTorch + Keras 3 (NVIDIA GPU + CUDA required).
# Designed for headless cloud instances (no GUI, runs inside tmux).
#
# USAGE (on the vast.ai instance):
#   1) Edit the CONFIG block below (CUDA version, paths, model, batch size).
#   2) chmod +x setup-vast.sh && ./setup-vast.sh install      # install deps
#      ./setup-vast.sh check                                   # verify GPU
#      ./setup-vast.sh train                                   # start training (in tmux)
#      ./setup-vast.sh board                                   # launch TensorBoard
#
# Tip: run inside tmux so training survives SSH drops:
#   tmux new -s fs   ->   ./setup-vast.sh train   ->   Ctrl+B then D to detach
#
set -euo pipefail

# ============================ CONFIG ============================
# Repo
REPO_URL="https://github.com/deepfakes/faceswap.git"
FS_DIR="${FS_DIR:-$HOME/faceswap}"          # where faceswap lives on the instance

# CUDA / requirements file. Pick the one matching the instance's CUDA toolkit:
#   requirements_nvidia_12.txt  -> CUDA 12.6 (torch cu126)
#   requirements_nvidia_13.txt  -> CUDA 13.0 (torch cu130, newest)
#   requirements_nvidia.txt     -> meta = latest (cu130)
REQ_FILE="${REQ_FILE:-requirements/requirements_nvidia_12.txt}"

# Skip torch reinstall if the base image already ships a matching torch+CUDA.
# Set to 1 to install ONLY the base deps (faster, avoids clobbering image torch).
SKIP_TORCH="${SKIP_TORCH:-0}"

# Training data + output (relative to $FS_DIR unless absolute)
FACES_A="${FACES_A:-workspace/faces_A}"      # extracted faces of identity A
FACES_B="${FACES_B:-workspace/faces_B}"      # extracted faces of identity B (the target)
MODEL_DIR="${MODEL_DIR:-workspace/model}"    # model + logs + snapshots saved here

# Training hyperparameters
TRAINER="${TRAINER:-phaze-a}"                # phaze-a | villain | dfl-sae | original | ...
BATCH_SIZE="${BATCH_SIZE:-16}"               # lower if you hit CUDA OOM (e.g. 8 or 4)
ITERATIONS="${ITERATIONS:-1000000}"
SAVE_INTERVAL="${SAVE_INTERVAL:-250}"        # save model every N iterations
SNAPSHOT_INTERVAL="${SNAPSHOT_INTERVAL:-25000}"  # full snapshot backup every N iters

# TensorBoard
TB_PORT="${TB_PORT:-6006}"

# Optional: auto-sync MODEL_DIR to remote storage every N seconds (0 = off).
# Requires `rclone` configured. Example remote: "gdrive:faceswap-model"
SYNC_REMOTE="${SYNC_REMOTE:-}"
SYNC_INTERVAL="${SYNC_INTERVAL:-1800}"       # 30 min
# ===============================================================

log() { printf '\033[1;32m[setup-vast]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[setup-vast]\033[0m %s\n' "$*" >&2; }

abspath() { case "$1" in /*) echo "$1";; *) echo "$FS_DIR/$1";; esac; }

cmd_install() {
  if [ ! -d "$FS_DIR/.git" ]; then
    log "Cloning faceswap into $FS_DIR"
    git clone "$REPO_URL" "$FS_DIR"
  else
    log "Repo already present at $FS_DIR — pulling latest"
    git -C "$FS_DIR" pull --ff-only || true
  fi

  cd "$FS_DIR"
  python -m pip install --upgrade pip

  if [ "$SKIP_TORCH" = "1" ]; then
    log "SKIP_TORCH=1 -> installing base deps only (keeping image torch)"
    pip install -r requirements/_requirements_base.txt
  else
    log "Installing $REQ_FILE (includes torch for the selected CUDA)"
    pip install -r "$REQ_FILE"
  fi
  log "Install complete."
}

cmd_check() {
  cd "$FS_DIR"
  python - <<'PY'
import torch
print("torch        :", torch.__version__)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU          :", torch.cuda.get_device_name(0))
    print("CUDA (torch) :", torch.version.cuda)
else:
    raise SystemExit("ERROR: CUDA not available — check the requirements file vs instance CUDA.")
PY
  log "GPU check passed."
}

# Upload MODEL_DIR -> Google Drive (or any rclone remote). Safe: copy never deletes.
do_sync() {
  [ -n "$SYNC_REMOTE" ] || return 0
  local m; m="$(abspath "$MODEL_DIR")"
  log "rclone copy $m -> $SYNC_REMOTE"
  rclone copy "$m" "$SYNC_REMOTE" || err "rclone copy failed (will retry next cycle)"
}

# Final sync on exit (Ctrl+C, training end, or instance stop signal) so the last
# minutes of progress are never lost between periodic sync cycles.
_on_exit() {
  [ -n "$SYNC_REMOTE" ] || return 0
  log "Process exiting -> running final sync to $SYNC_REMOTE"
  do_sync || true
}

cmd_train() {
  cd "$FS_DIR"
  local a b m
  a="$(abspath "$FACES_A")"; b="$(abspath "$FACES_B")"; m="$(abspath "$MODEL_DIR")"

  [ -d "$a" ] || { err "Faces A not found: $a (upload extracted faces first)"; exit 1; }
  [ -d "$b" ] || { err "Faces B not found: $b (upload extracted faces first)"; exit 1; }
  mkdir -p "$m"

  # Final-sync guard + periodic background sync loop
  if [ -n "$SYNC_REMOTE" ]; then
    trap _on_exit EXIT INT TERM
    log "Starting rclone sync loop -> $SYNC_REMOTE every ${SYNC_INTERVAL}s"
    ( while true; do sleep "$SYNC_INTERVAL"; rclone copy "$m" "$SYNC_REMOTE" 2>/dev/null || true; done ) &
  fi

  log "Training: trainer=$TRAINER batch=$BATCH_SIZE iters=$ITERATIONS"
  log "Logs (TensorBoard) enabled by default. NO GUI preview (-w writes preview images to disk)."
  # Headless flags:
  #   -w  : write preview image to file (instead of -p GUI window)
  #   -s  : save model every N iters
  #   -I  : snapshot backup every N iters
  #   (logs are ON by default; do NOT pass -n)
  python faceswap.py train \
    -A "$a" \
    -B "$b" \
    -m "$m" \
    -t "$TRAINER" \
    -b "$BATCH_SIZE" \
    -i "$ITERATIONS" \
    -s "$SAVE_INTERVAL" \
    -I "$SNAPSHOT_INTERVAL" \
    -w
}

cmd_board() {
  local m; m="$(abspath "$MODEL_DIR")"
  log "TensorBoard on 0.0.0.0:$TB_PORT  (map this port in vast.ai)"
  tensorboard --logdir "$m/logs" --host 0.0.0.0 --port "$TB_PORT"
}

# Manual one-off push of the current model to the remote.
cmd_sync() {
  [ -n "$SYNC_REMOTE" ] || { err "SYNC_REMOTE is empty. Set it, e.g. SYNC_REMOTE=gdrive:faceswap-model"; exit 1; }
  do_sync
}

# Pull model back FROM the remote into MODEL_DIR (resume training / convert locally).
cmd_pull() {
  [ -n "$SYNC_REMOTE" ] || { err "SYNC_REMOTE is empty. Set it, e.g. SYNC_REMOTE=gdrive:faceswap-model"; exit 1; }
  local m; m="$(abspath "$MODEL_DIR")"
  mkdir -p "$m"
  log "rclone copy $SYNC_REMOTE -> $m"
  rclone copy "$SYNC_REMOTE" "$m"
  log "Pull complete."
}

case "${1:-}" in
  install) cmd_install ;;
  check)   cmd_check ;;
  train)   cmd_train ;;
  board)   cmd_board ;;
  sync)    cmd_sync ;;
  pull)    cmd_pull ;;
  all)     cmd_install && cmd_check ;;
  *)
    cat <<EOF
Usage: $0 {install|check|train|board|sync|pull|all}

  install  Clone repo + pip install deps (edit REQ_FILE/SKIP_TORCH for your CUDA)
  check    Verify torch sees the GPU
  train    Start headless training (run inside tmux!). Auto-syncs if SYNC_REMOTE set,
           plus a final sync on exit (Ctrl+C / training end / stop signal).
  board    Launch TensorBoard on port $TB_PORT
  sync     Push MODEL_DIR -> SYNC_REMOTE once (manual)
  pull     Pull model FROM SYNC_REMOTE -> MODEL_DIR (resume/convert)
  all      install + check

Override config via env vars, e.g.:
  REQ_FILE=requirements/requirements_nvidia_13.txt SKIP_TORCH=1 $0 install
  TRAINER=villain BATCH_SIZE=8 $0 train
  SYNC_REMOTE=gdrive:faceswap-model $0 train
  SYNC_REMOTE=gdrive:faceswap-model $0 pull
EOF
    exit 1 ;;
esac
