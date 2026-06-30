#!/usr/bin/env python3
"""RunPod Serverless: faceswap extract on GPU + transfer faces via Cloudflare R2.

One file, two roles (the worker image runs this same module, so it MUST stay a
valid importable module — snake_case name, no top-level side effects):

    serve    runpod.serverless.start(): block and process jobs (Docker CMD)
    submit   POST one job to the RunPod endpoint, print the result

Flow inside a worker (one extract job):
    R2 --(rclone copy)--> /workspace/sl/jobs/<id>/in
        --> python faceswap.py extract --> .../faces (+ optional dedupe)
        --(rclone copy)--> R2/<r2_dst>

rclone copy is synchronous — it blocks until the transfer finishes, so there is
no status-polling loop (unlike vast cloud copy). R2 is S3-compatible; rclone is
configured entirely via RCLONE_CONFIG_R2_* env vars set as RunPod endpoint
secrets, so no rclone.conf file is needed on the worker.

Auth is split: RUNPOD_API_KEY (control machine) submits jobs and is never baked
into the image; the worker's R2 credentials (RCLONE_CONFIG_R2_*) are RunPod
endpoint secrets, never committed to the repo.

Requires `requests` locally for submit; `runpod` + `rclone` on the worker image.
"""
import argparse
import asyncio
import json
import os
import shutil
import shlex
import uuid
from pathlib import PurePosixPath

# --- Constants / env --------------------------------------------------------

RUNPOD_API_KEY = os.environ.get("RUNPOD_API_KEY", "")
RUNPOD_ENDPOINT_ID = os.environ.get("RUNPOD_ENDPOINT_ID", "")
RUNPOD_API_BASE = os.environ.get("RUNPOD_API_BASE", "https://api.runpod.ai/v2")
R2_BUCKET = os.environ.get("R2_BUCKET", "faceswap")

FACESWAP_DIR = os.environ.get("FACESWAP_DIR", "/workspace/faceswap")
WORK_ROOT = os.environ.get("WORK_ROOT", "/workspace/sl")
DEDUPE_REMOTE = f"{WORK_ROOT}/dedupe_faces.py"


async def _run(cmd: str, stream: bool = False) -> str:
    """Run a shell command, raise with output on failure.

    stream=False (default): capture combined stdout/stderr and return it.
    stream=True: inherit the parent's stdout/stderr so long-running output (e.g.
    faceswap's per-frame progress, rclone --progress) shows live in the worker
    container log; returns "" since nothing is captured.
    """
    pipe = None if stream else asyncio.subprocess.PIPE
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=pipe,
        stderr=None if stream else asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    text = (out or b"").decode("utf-8", "replace")
    if proc.returncode != 0:
        raise RuntimeError(f"cmd failed ({proc.returncode}): {cmd}\n{text}")
    return text


# --- rclone helpers (Cloudflare R2, synchronous) ----------------------------

async def _r2_download(r2_src: str, local_dir: str) -> None:
    """rclone copy r2:<bucket>/<r2_src> <local_dir> — blocks until done."""
    remote = shlex.quote(f"r2:{R2_BUCKET}/{r2_src}")
    await _run(
        f"rclone copy {remote} {shlex.quote(local_dir)} --progress",
        stream=True,
    )


async def _r2_upload(local_dir: str, r2_dst: str) -> None:
    """rclone copy <local_dir> r2:<bucket>/<r2_dst> — blocks until done."""
    remote = shlex.quote(f"r2:{R2_BUCKET}/{r2_dst}")
    await _run(
        f"rclone copy {shlex.quote(local_dir)} {remote} --progress",
        stream=True,
    )


def _safe_input_path(in_dir: str, input_name: str) -> str:
    """Resolve a worker-local relative input and reject path traversal."""
    path = PurePosixPath(input_name)
    if not input_name or path.is_absolute() or ".." in path.parts:
        raise ValueError("input_name must be a non-empty relative path without '..'")
    return f"{in_dir}/{path.as_posix()}"


# --- RunPod handler (worker role) -------------------------------------------

async def _extract_async(job_input: dict) -> dict:
    """Extract faces from one media file pulled from R2, push faces back to R2.

    job_input keys:
        input_name   media filename inside r2_src (video or frame dir)
        r2_src       R2 path holding input_name
        r2_dst       R2 path to receive the extracted faces
        detector, aligner, extract_size, extract_norm, dedupe_threshold (optional)
    """
    input_name = job_input["input_name"]
    r2_src = job_input["r2_src"]
    r2_dst = job_input["r2_dst"]
    detector = job_input.get("detector", "retinaface")
    aligner = job_input.get("aligner", "hrnet")
    extract_size = int(job_input.get("extract_size", 512))
    extract_norm = job_input.get("extract_norm", "hist")
    dedupe_threshold = int(job_input.get("dedupe_threshold", 6))

    job_root = f"{WORK_ROOT}/jobs/{uuid.uuid4().hex}"
    in_dir = f"{job_root}/in"
    faces_dir = f"{job_root}/faces"
    os.makedirs(in_dir, exist_ok=True)
    os.makedirs(faces_dir, exist_ok=True)

    input_path = _safe_input_path(in_dir, input_name)

    # Stage markers print to the worker log so a long job is observably alive.
    def _stage(msg: str) -> None:
        print(f"[sl] {msg}", flush=True)

    try:
        # 1. R2 -> worker. rclone copy is synchronous; no poll loop needed.
        _stage(f"1/4 download {r2_src} -> worker")
        await _r2_download(r2_src, in_dir)

        # 2. Extract faces on GPU. Stream output so progress shows live.
        _stage(f"2/4 extract {input_name} (D={detector} A={aligner})")
        extract_cmd = (
            f"cd {shlex.quote(FACESWAP_DIR)} && python faceswap.py extract "
            f"-i {shlex.quote(input_path)} -o {shlex.quote(faces_dir)} "
            f"-D {shlex.quote(detector)} -A {shlex.quote(aligner)} "
            f"-z {int(extract_size)} -O {shlex.quote(extract_norm)}"
        )
        await _run(extract_cmd, stream=True)

        def _png_count(d: str) -> int:
            return len([f for f in os.listdir(d) if f.lower().endswith(".png")])

        # 3. Optional dedupe (mirrors local dHash thinning). Skip when extract
        # produced nothing — dedupe on an empty dir would fail the job instead
        # of returning the intended ok:false soft-failure.
        if dedupe_threshold and int(dedupe_threshold) > 0 and _png_count(faces_dir) > 0:
            _stage(f"3/4 dedupe (thresh={int(dedupe_threshold)})")
            deduped = f"{job_root}/faces_deduped"
            await _run(
                f"SRC={shlex.quote(faces_dir)} OUT={shlex.quote(deduped)} "
                f"THRESH={int(dedupe_threshold)} python {shlex.quote(DEDUPE_REMOTE)}"
            )
            faces_dir = deduped

        count = _png_count(faces_dir)

        # 4. worker -> R2 (extracted faces) — skip if nothing extracted.
        if count > 0:
            _stage(f"4/4 upload {count} faces -> {r2_dst}")
            await _r2_upload(faces_dir, r2_dst)

        return {
            "ok": count > 0,  # zero faces = soft failure (bad input / no detections)
            "input": input_name,
            "faces": count,
            "r2_dst": r2_dst if count > 0 else None,
            "log_note": "extract output streamed to worker log (RunPod console)",
        }
    finally:
        shutil.rmtree(job_root, ignore_errors=True)


async def handler(job: dict) -> dict:
    """RunPod entrypoint: async handler so the SDK's event loop can await it."""
    return await _extract_async(job["input"])


def _serve() -> None:
    """Start the RunPod worker loop (blocks waiting for jobs)."""
    import runpod

    runpod.serverless.start({"handler": handler})


# --- CLI --------------------------------------------------------------------

def _submit(a: argparse.Namespace) -> None:
    """POST one extract job to the RunPod endpoint and print the response."""
    if not RUNPOD_API_KEY:
        raise RuntimeError("RUNPOD_API_KEY is not set — required to submit jobs.")
    if not RUNPOD_ENDPOINT_ID:
        raise RuntimeError("RUNPOD_ENDPOINT_ID is not set — required to submit jobs.")

    import requests

    payload = {"input": {
        "input_name": a.input,
        "r2_src": a.r2_src,
        "r2_dst": a.r2_dst,
        "detector": a.detector,
        "aligner": a.aligner,
        "extract_size": a.extract_size,
        "extract_norm": a.extract_norm,
        "dedupe_threshold": a.dedupe_threshold,
    }}
    # /runsync blocks until the job finishes (or the client timeout elapses),
    # so the result JSON is returned directly — no separate status poll needed.
    url = f"{RUNPOD_API_BASE}/{RUNPOD_ENDPOINT_ID}/runsync"
    resp = requests.post(
        url,
        json=payload,
        headers={"Authorization": f"Bearer {RUNPOD_API_KEY}"},
        timeout=a.timeout,
    )
    resp.raise_for_status()
    print(json.dumps(resp.json(), indent=2))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    sub.add_parser("serve", help="start the RunPod worker loop (Docker CMD)")

    s = sub.add_parser("submit", help="POST one extract job to the endpoint")
    s.add_argument("--input", required=True, help="media filename inside r2_src")
    s.add_argument("--r2-src", dest="r2_src", required=True)
    s.add_argument("--r2-dst", dest="r2_dst", required=True)
    s.add_argument("--detector", default="retinaface")
    s.add_argument("--aligner", default="hrnet")
    s.add_argument("--extract-size", dest="extract_size", type=int, default=512)
    s.add_argument("--extract-norm", dest="extract_norm", default="hist")
    s.add_argument("--dedupe-threshold", dest="dedupe_threshold", type=int, default=6)
    s.add_argument("--timeout", type=int, default=600, help="client wait for runsync (s)")

    a = p.parse_args()
    if a.mode == "serve":
        _serve()
    else:
        _submit(a)


if __name__ == "__main__":
    main()
