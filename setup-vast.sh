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
# Backend selection (headless / non-interactive). Without these, the first run
# prompts for a backend on stdin and Keras 3 defaults to the TensorFlow path
# (ModuleNotFoundError: tensorflow). faceswap needs the PyTorch backend.
export FACESWAP_BACKEND="${FACESWAP_BACKEND:-nvidia}"
export KERAS_BACKEND="${KERAS_BACKEND:-torch}"
# ===============================================================

log() { printf '\033[1;32m[setup-vast]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[setup-vast]\033[0m %s\n' "$*" >&2; }

# Resolve a usable interpreter: some images expose only `python3` (no `python`).
PY="$(command -v python || command -v python3)"
[ -n "$PY" ] || { err "No python/python3 on PATH (activate the venv first)"; exit 1; }

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
  "$PY" -m pip install --upgrade pip

  if [ "$SKIP_TORCH" = "1" ]; then
    log "SKIP_TORCH=1 -> installing base deps only (keeping image torch)"
    pip install -r requirements/_requirements_base.txt
  else
    log "Installing $REQ_FILE (includes torch for the selected CUDA)"
    pip install -r "$REQ_FILE"
  fi

  patch_preview_path
  log "Install complete."
}

# Faceswap writes the training preview to the faceswap.py directory by default. Redirect it to
# the model dir (e.g. /workspace/train/model) so it lives under the synced data dir (vast.ai
# console / Google Drive sync of /workspace). Idempotent — safe to re-run. Upstream clone only.
patch_preview_path() {
  local f="$FS_DIR/scripts/train.py"
  local old='img_file = os.path.join(script_path, img)'
  local new='img_file = os.path.join(self._args.model_dir if os.path.isdir(self._args.model_dir) else script_path, img)'
  [ -f "$f" ] || return 0
  if grep -qF "$new" "$f"; then
    log "Preview path patch already applied."
  elif grep -qF "$old" "$f"; then
    "$PY" - "$f" "$old" "$new" <<'PY'
import sys
f, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
open(f, "w").write(s.replace(old, new, 1))
print("[setup-vast] Patched preview output -> model dir")
PY
  else
    err "Preview path target line not found in $f — skipping (faceswap changed?)."
  fi
}

cmd_check() {
  cd "$FS_DIR"
  "$PY" - <<'PY'
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
  "$PY" faceswap.py train \
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

# Self-contained vast.ai Cloud Sync via cron: instance periodically calls the vast API
# (`vastai cloud copy`) to push SYNC_SRC -> a cloud connection (e.g. Google Drive). Runs
# ON the instance, independent of the local machine.
#   Auth: the (scoped) API key comes from the VAST_API_KEY env var — NOT a key file. It is
#   baked into the crontab header so cron jobs inherit it (cron uses a minimal env). Provide it
#   when running this command: VAST_API_KEY=<scoped-key> ./setup-vast.sh cloudsync
#   (set the same key as a vast account env-var so future instances get it auto-injected:
#    vastai create env-var VAST_API_KEY <scoped-key>).
#   Config: CC_INSTANCE_ID (this instance), CC_CONNECTION_ID (from `vastai show connections`),
#           SYNC_SRC, CC_DST, CC_INTERVAL_MIN.
CC_INSTANCE_ID="${CC_INSTANCE_ID:-}"
CC_CONNECTION_ID="${CC_CONNECTION_ID:-}"
SYNC_SRC="${SYNC_SRC:-/workspace/train}"
CC_DST="${CC_DST:-/faceswap-train}"
CC_INTERVAL_MIN="${CC_INTERVAL_MIN:-10}"

cmd_cloudsync() {
  [ -n "$CC_INSTANCE_ID" ] && [ -n "$CC_CONNECTION_ID" ] || {
    err "Set CC_INSTANCE_ID and CC_CONNECTION_ID (see: vastai show connections)"; exit 1; }
  # vastai is pre-installed by vast at /opt/instance-tools/bin; resolve it generically.
  local vastai_bin; vastai_bin="$(command -v vastai || true)"
  [ -n "$vastai_bin" ] || { err "vastai CLI not found on instance"; exit 1; }
  local key="${VAST_API_KEY:-}"
  [ -n "$key" ] || { err "Set VAST_API_KEY=<scoped cloud-copy key> before running cloudsync"; exit 1; }
  local bindir; bindir="$(dirname "$vastai_bin")"

  cat > /root/cloud-sync.sh <<EOF
#!/usr/bin/env bash
# Full PATH so cron (minimal env) finds vastai. Key is provided via VAST_API_KEY (crontab env).
export PATH=$bindir:/opt/instance-tools/bin:/venv/main/bin:/usr/local/bin:/usr/bin:/bin
ts="\$(date '+%F %T')"
out="\$(vastai cloud copy --src $SYNC_SRC --dst $CC_DST --instance $CC_INSTANCE_ID --connection $CC_CONNECTION_ID --transfer 'Instance To Cloud' 2>&1)"
echo "[\$ts] \$out" >> /root/cloud-sync.log
EOF
  chmod +x /root/cloud-sync.sh

  # Rebuild crontab: VAST_API_KEY env line + schedule. Strip any prior key/cron lines first.
  local rest; rest="$(crontab -l 2>/dev/null | grep -vE '^VAST_API_KEY=|/root/cloud-sync.sh' || true)"
  printf 'VAST_API_KEY=%s\n%s\n*/%s * * * * /root/cloud-sync.sh\n' "$key" "$rest" "$CC_INTERVAL_MIN" | crontab -
  log "Cloud Sync cron installed (key via VAST_API_KEY env, no key file): every ${CC_INTERVAL_MIN}m"
  log "Test run:"; VAST_API_KEY="$key" /root/cloud-sync.sh; tail -1 /root/cloud-sync.log
}

case "${1:-}" in
  install) cmd_install ;;
  check)   cmd_check ;;
  train)   cmd_train ;;
  board)   cmd_board ;;
  sync)    cmd_sync ;;
  pull)    cmd_pull ;;
  cloudsync) cmd_cloudsync ;;
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
  cloudsync  Install cron on the instance to auto-run vast.ai Cloud Copy -> Drive
             (needs CC_INSTANCE_ID, CC_CONNECTION_ID, and VAST_API_KEY env — no key file)
  all      install + check

Override config via env vars, e.g.:
  REQ_FILE=requirements/requirements_nvidia_13.txt SKIP_TORCH=1 $0 install
  TRAINER=villain BATCH_SIZE=8 $0 train
  SYNC_REMOTE=gdrive:faceswap-model $0 train
  SYNC_REMOTE=gdrive:faceswap-model $0 pull
EOF
    exit 1 ;;
esac
