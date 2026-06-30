# Serverless worker base image: faceswap + CUDA 12.6 + torch cu126.
# Built ONCE via .github/workflows/build-serverless-image.yml (or manually).
# The Vast Serverless deployment does FROM this image — no git clone / pip at cold start.
#
# Built by CI: .github/workflows/build-serverless-image.yml (pushes to ghcr.io with zstd).
# To build locally (amd64 only — Vast workers are x86_64):
#   docker buildx build --platform linux/amd64 -f docker/serverless/Dockerfile \
#     --output type=image,compression=zstd,force-compression=false,push=true \
#     --tag ghcr.io/tranngoclai/faceswap-sl:cu126 .

# CUDA 12.6 + cuDNN 9 — matches sl_base_image vastai/base-image:cuda-12.8-auto driver floor.
# Use nvidia/cuda rather than vastai/base-image so we can build on standard runners
# without a Vast-specific base that is not on Docker Hub.
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
        git \
        python3-pip \
        python3-venv \
        python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

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
    && rm -rf /tmp/requirements

# 4. Dedupe helper (small, changes independently of deps).
COPY scripts/cloud/dedupe_faces.py ${WORK_ROOT}/dedupe_faces.py

WORKDIR ${FACESWAP_DIR}
