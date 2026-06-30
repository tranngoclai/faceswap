# RunPod Serverless worker image: faceswap + CUDA 12.6 + torch cu126 + rclone.
# Built ONCE via .github/workflows/build-serverless-image.yml (or manually).
# RunPod runs this image directly (CMD below starts the worker) — no git clone /
# pip at cold start.
#
# Built by CI: .github/workflows/build-serverless-image.yml (pushes to ghcr.io with zstd).
# To build locally (amd64 only — RunPod workers are x86_64):
#   docker buildx build --platform linux/amd64 -f docker/serverless/Dockerfile \
#     --output type=image,compression=zstd,force-compression=false,push=true \
#     --tag ghcr.io/tranngoclai/faceswap-sl:cu126 .

# CUDA 12.6 + cuDNN 9 — RunPod supports CUDA 12.x. nvidia/cuda is a standard base
# buildable on any runner.
FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    FACESWAP_DIR=/workspace/faceswap \
    WORK_ROOT=/workspace/sl \
    FACESWAP_BACKEND=nvidia \
    KERAS_BACKEND=torch \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# 1. System deps — kept minimal; ffmpeg-binaries (PyPI) ships its own ffmpeg
#    so the system package is optional but avoids missing-codec edge cases.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates \
        curl \
        ffmpeg \
        unzip \
        git \
        python3-pip \
        python3-tk \
        python3-venv \
        python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# 1b. rclone (R2 transfers). Direct GitHub release download works in Docker;
#     the rclone.org install script fails in some build environments (exit 4).
#     R2 chunked upload support requires rclone >= 1.62.
RUN curl -fsSL https://github.com/rclone/rclone/releases/latest/download/rclone-current-linux-amd64.zip \
        -o /tmp/rclone.zip \
    && unzip /tmp/rclone.zip -d /tmp/rclone \
    && cp /tmp/rclone/rclone-*-linux-amd64/rclone /usr/bin/rclone \
    && chmod 755 /usr/bin/rclone \
    && rm -rf /tmp/rclone /tmp/rclone.zip

# 2. Clone faceswap. Drop .git to shrink the layer.
#    A version bump here only invalidates layers 2+ (not the apt layer).
ARG FACESWAP_REPO=https://github.com/deepfakes/faceswap.git
RUN git clone --depth 1 "${FACESWAP_REPO}" "${FACESWAP_DIR}" \
    && rm -rf "${FACESWAP_DIR}/.git"

# 3. Python deps (torch cu126 ~2 GB — separated so a req file change
#    does not re-clone the repo, and a repo change does not re-run pip).
COPY requirements/_requirements_base.txt requirements/requirements_nvidia_12.txt \
     /tmp/requirements/
RUN pip install --no-cache-dir --break-system-packages \
        -r /tmp/requirements/requirements_nvidia_12.txt \
        runpod \
    && rm -rf /tmp/requirements

# 4. Worker scripts (small, change independently of deps).
COPY scripts/cloud/dedupe_faces.py ${WORK_ROOT}/dedupe_faces.py
COPY scripts/cloud/serverless_extract.py ${WORK_ROOT}/serverless_extract.py

WORKDIR ${FACESWAP_DIR}

# RunPod starts the worker via the image's default command.
CMD ["python", "/workspace/sl/serverless_extract.py", "serve"]
