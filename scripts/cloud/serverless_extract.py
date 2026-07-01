#!/usr/bin/env python3
"""RunPod Serverless: faceswap extract on GPU + transfer faces via Google Drive.

One file, two roles (the worker image runs this same module, so it MUST stay a
valid importable module — snake_case name, no top-level side effects):

    serve    runpod.serverless.start(): block and process jobs (Docker CMD)
    submit   POST one job to the RunPod endpoint, print the result

Flow inside a worker (one extract job):
    gdrive:<gdrive_src> --(rclone copy)--> /workspace/sl/jobs/<id>/in
        --> python faceswap.py extract --> .../faces (+ optional dedupe)
        --(rclone copy)--> gdrive:<gdrive_dst>

Auth: the worker reads GDRIVE_REFRESH_TOKEN (RunPod template env, < 256 chars) and
reconstructs a minimal token JSON so rclone can refresh access tokens automatically.
GDRIVE_TOKEN_JSON (full JSON) is accepted as an override for local dev. No rclone.conf
file is needed on the worker container.

Control-machine submit: RUNPOD_API_KEY must be set in the environment. If
/runsync returns IN_PROGRESS the CLI polls /status/{id} until terminal.

Requires `requests` locally for submit; `runpod` + `rclone` on the worker image.
"""
import argparse
import asyncio
import json
import os
import shutil
import shlex
import subprocess
import uuid
from pathlib import PurePosixPath

# --- Constants / env --------------------------------------------------------

RUNPOD_API_KEY = os.environ.get("RUNPOD_API_KEY", "")
RUNPOD_ENDPOINT_ID = os.environ.get("RUNPOD_ENDPOINT_ID", "")
RUNPOD_API_BASE = os.environ.get("RUNPOD_API_BASE", "https://api.runpod.ai/v2")

GDRIVE_REMOTE = os.environ.get("GDRIVE_REMOTE", "gdrive")
GDRIVE_TOKEN_JSON = os.environ.get("GDRIVE_TOKEN_JSON", "")
# RunPod template env vars are capped at 256 chars; a full token JSON is 400-600 chars.
# GDRIVE_REFRESH_TOKEN stores only the refresh_token (~80 chars); _setup_gdrive reconstructs
# a minimal token JSON so rclone can obtain a fresh access_token automatically.
GDRIVE_REFRESH_TOKEN = os.environ.get("GDRIVE_REFRESH_TOKEN", "")
GDRIVE_ROOT_FOLDER_ID = os.environ.get("GDRIVE_ROOT_FOLDER_ID", "")

FACESWAP_DIR = os.environ.get("FACESWAP_DIR", "/workspace/faceswap")
WORK_ROOT = os.environ.get("WORK_ROOT", "/workspace/sl")
DEDUPE_SCRIPT = f"{WORK_ROOT}/dedupe_faces.py"

# Subprocess timeout knobs — tune via env vars on the RunPod endpoint secret.
RCLONE_TIMEOUT_S = int(os.environ.get("RCLONE_TIMEOUT_S", "600"))   # 10 min per transfer
EXTRACT_TIMEOUT_S = int(os.environ.get("EXTRACT_TIMEOUT_S", "1800"))  # 30 min for GPU extract


def _setup_gdrive() -> None:
    """Configure rclone Google Drive remote via environment variables.

    Priority:
      1. GDRIVE_TOKEN_JSON  — full token JSON (local dev / manual override)
      2. GDRIVE_REFRESH_TOKEN — refresh_token only (RunPod template env, < 256 chars);
         a minimal token JSON is reconstructed so rclone refreshes the access_token itself.

    No-op when neither is set (assumes rclone.conf pre-configured).
    """
    token_json = GDRIVE_TOKEN_JSON
    if not token_json and GDRIVE_REFRESH_TOKEN:
        # Reconstruct minimal token JSON. access_token is intentionally expired so
        # rclone uses the refresh_token to obtain a fresh one on first use.
        token_json = json.dumps({
            "access_token": "x",
            "refresh_token": GDRIVE_REFRESH_TOKEN,
            "token_type": "Bearer",
            "expiry": "2006-01-02T15:04:05.000000000Z",
        }, separators=(",", ":"))

    if not token_json:
        return

    try:
        token = json.loads(token_json)
    except json.JSONDecodeError as exc:
        raise RuntimeError("GDRIVE_TOKEN_JSON is not valid JSON") from exc
    if not token.get("refresh_token"):
        raise RuntimeError("Google Drive token must contain refresh_token")
    if not GDRIVE_REMOTE.replace("_", "").isalnum():
        raise RuntimeError("GDRIVE_REMOTE must contain only letters, digits, or underscores")

    prefix = f"RCLONE_CONFIG_{GDRIVE_REMOTE.upper()}"
    os.environ[f"{prefix}_TYPE"] = "drive"
    os.environ[f"{prefix}_SCOPE"] = "drive"
    os.environ[f"{prefix}_TOKEN"] = json.dumps(token, separators=(",", ":"))
    if GDRIVE_ROOT_FOLDER_ID:
        os.environ[f"{prefix}_ROOT_FOLDER_ID"] = GDRIVE_ROOT_FOLDER_ID


async def _run(
    cmd: str,
    stream: bool = False,
    timeout_s: int | None = None,
    extra_env: dict[str, str] | None = None,
) -> str:
    """Run a shell command, raise with output on failure.

    stream=False (default): capture combined stdout/stderr and return it.
    stream=True: inherit the parent's stdout/stderr so long-running output (e.g.
    faceswap's per-frame progress, rclone --progress) shows live in the worker
    container log; returns "" since nothing is captured.
    timeout_s: hard wall-clock limit in seconds; raises TimeoutError on breach.
    extra_env: additional env vars merged on top of os.environ for the subprocess.
    """
    pipe = None if stream else asyncio.subprocess.PIPE
    env = {**os.environ, **extra_env} if extra_env else None
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=pipe,
        stderr=None if stream else asyncio.subprocess.STDOUT,
        env=env,
    )
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout_s)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.communicate()
        raise TimeoutError(f"cmd timed out after {timeout_s}s: {cmd}")
    text = (out or b"").decode("utf-8", "replace")
    if proc.returncode != 0:
        raise RuntimeError(f"cmd failed ({proc.returncode}): {cmd}\n{text}")
    return text


# --- rclone helpers (Google Drive) ------------------------------------------

async def _gdrive_download(gdrive_src: str, local_dir: str) -> None:
    """rclone copy gdrive:<gdrive_src> <local_dir>"""
    remote = shlex.quote(f"{GDRIVE_REMOTE}:{gdrive_src}")
    out = await _run(f"rclone copy {remote} {shlex.quote(local_dir)} -v", timeout_s=RCLONE_TIMEOUT_S)
    if out:
        print(f"[rclone download] {out}", flush=True)


async def _gdrive_upload(local_dir: str, gdrive_dst: str) -> None:
    """rclone copy <local_dir> gdrive:<gdrive_dst>"""
    remote = shlex.quote(f"{GDRIVE_REMOTE}:{gdrive_dst}")
    out = await _run(f"rclone copy {shlex.quote(local_dir)} {remote} -v", timeout_s=RCLONE_TIMEOUT_S)
    if out:
        print(f"[rclone upload] {out}", flush=True)


def _safe_input_path(in_dir: str, input_name: str) -> str:
    """Resolve a worker-local relative input and reject path traversal."""
    path = PurePosixPath(input_name)
    if not input_name or path.is_absolute() or ".." in path.parts:
        raise ValueError("input_name must be a non-empty relative path without '..'")
    return f"{in_dir}/{path.as_posix()}"


# --- RunPod handler (worker role) -------------------------------------------

async def _extract_async(job_input: dict) -> dict:
    """Extract faces from one media file pulled from Drive, push faces back to Drive.

    job_input keys:
        input_name   media filename inside gdrive_src (video or frame dir)
        gdrive_src   Drive path holding input_name (relative to root_folder_id)
        gdrive_dst   Drive path to receive the extracted faces
        detector, aligner, extract_size, extract_norm, dedupe_threshold (optional)
    """
    input_name = job_input["input_name"]
    gdrive_src = job_input["gdrive_src"]
    gdrive_dst = job_input["gdrive_dst"]
    detector = job_input.get("detector", "retinaface")
    aligner = job_input.get("aligner", "hrnet")
    extract_size = int(job_input.get("extract_size", 512))
    extract_norm = job_input.get("extract_norm", "hist")
    dedupe_threshold = int(job_input.get("dedupe_threshold", 6))

    # Re-run setup each job so rotated OAuth/SA credentials take effect.
    await asyncio.to_thread(_setup_gdrive)

    job_root = f"{WORK_ROOT}/jobs/{uuid.uuid4().hex}"
    in_dir = f"{job_root}/in"
    faces_dir = f"{job_root}/faces"
    os.makedirs(in_dir, exist_ok=True)
    os.makedirs(faces_dir, exist_ok=True)

    input_path = _safe_input_path(in_dir, input_name)

    def _stage(msg: str) -> None:
        print(f"[sl] {msg}", flush=True)

    try:
        _stage(f"1/4 download {gdrive_src} -> worker")
        await _gdrive_download(gdrive_src, in_dir)

        if not os.path.exists(input_path):
            raise FileNotFoundError(
                f"Input file not found after download: {input_name!r}. "
                f"Ensure the file exists at Drive path {gdrive_src}/{input_name}"
            )

        _stage(f"2/4 extract {input_name} (D={detector} A={aligner})")
        extract_cmd = (
            f"cd {shlex.quote(FACESWAP_DIR)} && python faceswap.py extract "
            f"-i {shlex.quote(input_path)} -o {shlex.quote(faces_dir)} "
            f"-D {shlex.quote(detector)} -A {shlex.quote(aligner)} "
            f"-z {int(extract_size)} -O {shlex.quote(extract_norm)}"
        )
        await _run(extract_cmd, stream=True, timeout_s=EXTRACT_TIMEOUT_S)

        def _png_count(d: str) -> int:
            return len([f for f in os.listdir(d) if f.lower().endswith(".png")])

        if dedupe_threshold and dedupe_threshold > 0 and _png_count(faces_dir) > 0:
            _stage(f"3/4 dedupe (thresh={dedupe_threshold})")
            deduped = f"{job_root}/faces_deduped"
            await _run(
                f"python {shlex.quote(DEDUPE_SCRIPT)}",
                extra_env={
                    "SRC": faces_dir,
                    "OUT": deduped,
                    "THRESH": str(int(dedupe_threshold)),
                },
                timeout_s=RCLONE_TIMEOUT_S,
            )
            faces_dir = deduped

        count = _png_count(faces_dir)

        if count > 0:
            _stage(f"4/4 upload {count} faces -> {gdrive_dst}")
            await _gdrive_upload(faces_dir, gdrive_dst)

        return {
            "ok": count > 0,
            "input": input_name,
            "faces": count,
            "gdrive_dst": gdrive_dst if count > 0 else None,
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

    _setup_gdrive()  # warm path: configure once at startup; also redone per-job
    runpod.serverless.start({"handler": handler})


# --- CLI --------------------------------------------------------------------

def _submit(a: argparse.Namespace) -> None:
    """POST one extract job to the RunPod endpoint and print the response."""
    if not RUNPOD_API_KEY:
        raise RuntimeError("RUNPOD_API_KEY is not set — required to submit jobs.")
    if not RUNPOD_ENDPOINT_ID:
        raise RuntimeError("RUNPOD_ENDPOINT_ID is not set — required to submit jobs.")

    import requests
    import time

    payload = {"input": {
        "input_name": a.input,
        "gdrive_src": a.gdrive_src,
        "gdrive_dst": a.gdrive_dst,
        "detector": a.detector,
        "aligner": a.aligner,
        "extract_size": a.extract_size,
        "extract_norm": a.extract_norm,
        "dedupe_threshold": a.dedupe_threshold,
    }}

    url = f"{RUNPOD_API_BASE}/{RUNPOD_ENDPOINT_ID}/runsync"
    headers = {"Authorization": f"Bearer {RUNPOD_API_KEY}"}
    resp = requests.post(url, json=payload, headers=headers, timeout=a.timeout)
    resp.raise_for_status()
    result = resp.json()

    # Poll /status/{id} until terminal when runsync returns IN_PROGRESS
    job_id = result.get("id")
    deadline = time.monotonic() + a.timeout
    while result.get("status") == "IN_PROGRESS" and job_id:
        if time.monotonic() >= deadline:
            print(json.dumps({"error": f"timeout after {a.timeout}s", "id": job_id}, indent=2))
            return
        time.sleep(5)
        sr = requests.get(
            f"{RUNPOD_API_BASE}/{RUNPOD_ENDPOINT_ID}/status/{job_id}",
            headers=headers,
            timeout=30,
        )
        sr.raise_for_status()
        result = sr.json()

    print(json.dumps(result, indent=2))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    sub.add_parser("serve", help="start the RunPod worker loop (Docker CMD)")

    s = sub.add_parser("submit", help="POST one extract job to the endpoint")
    s.add_argument("--input", required=True, help="media filename inside gdrive_src")
    s.add_argument("--gdrive-src", dest="gdrive_src", required=True,
                   help="Drive path for input (relative to root_folder_id)")
    s.add_argument("--gdrive-dst", dest="gdrive_dst", required=True,
                   help="Drive path to receive extracted faces")
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
