#!/usr/bin/env python3
"""Vast.ai Serverless deployment: faceswap extract on GPU + upload to Google Drive.

One file, two roles (the vast SDK imports this same module on the worker, so it
MUST stay a valid importable module — snake_case name, no top-level side effects
beyond the deployment definition):

    deploy   provision/refresh the serverless endpoint
    submit   ensure the endpoint is current, send one job, print the result

Flow inside a worker (one extract job):
    Drive --(vast cloud copy: Cloud To Instance)--> /workspace/sl/in
        --> python faceswap.py extract --> /workspace/sl/faces (+ optional dedupe)
        --(vast cloud copy: Instance To Cloud)--> Drive/<dst>

Auth is deliberately split: VAST_DEPLOY_API_KEY provisions/routes the deployment
on the control machine; the worker's VAST_API_KEY (scoped to instance_read +
api.commands.rclone POST) is injected automatically by Vast as an encrypted
account environment variable — never baked into the deployment image definition.
Never reuse the deploy key as the worker key.

Requires the vast SDK locally:  pip install vastai
"""
import argparse
import asyncio
import json
import os
import shutil
import shlex
import time
import uuid
from pathlib import PurePosixPath

from vastai.serverless.remote import Deployment

# --- Deployment definition (shared by deploy + serve modes) -----------------

DEPLOYMENT_NAME = os.environ.get("SL_ENDPOINT_NAME", "faceswap-extract")
# Prebuilt image (ghcr.io/tranngoclai/faceswap-sl:cu126) has faceswap + torch cu126
# baked in — no git clone / pip at cold start. Build via:
#   git tag sl-<version> && git push origin sl-<version>
# Fall back to the slow vanilla base only when SL_BASE_IMAGE is overridden.
BASE_IMAGE = os.environ.get("SL_BASE_IMAGE", "ghcr.io/tranngoclai/faceswap-sl:cu126")
FACESWAP_DIR = "/workspace/faceswap"
WORK_ROOT = "/workspace/sl"
DEDUPE_REMOTE = f"{WORK_ROOT}/dedupe_faces.py"

# Never bake the deploy credential into the worker. The deploy key provisions and
# routes Serverless requests; the narrow cloud-copy key only runs rclone + reads
# the worker instance status so transfers can be awaited safely.
DEPLOY_API_KEY = os.environ.get("VAST_DEPLOY_API_KEY", "")
CONNECTION_ID = os.environ.get("SL_CONNECTION_ID", "")
TRANSFER_TIMEOUT = int(os.environ.get("SL_TRANSFER_TIMEOUT", "1800"))
TRANSFER_POLL_INTERVAL = float(os.environ.get("SL_TRANSFER_POLL_INTERVAL", "3"))

# Pass api_key only when set; otherwise let the SDK use the stored key
# (`vastai set api-key`). In serve mode (on the worker) this kwarg is ignored.
_dep_kwargs = {"api_key": DEPLOY_API_KEY} if DEPLOY_API_KEY else {}
deployment = Deployment(name=DEPLOYMENT_NAME, **_dep_kwargs)

# Image is prebuilt (faceswap + torch cu126 baked in); only set runtime env.
# VAST_API_KEY is NOT set here — injected automatically by Vast account secrets.
_img = deployment.image(BASE_IMAGE, storage=int(os.environ.get("SL_DISK_GB", "60")))
_img.use_system_python()
_img.env(
    FACESWAP_BACKEND="nvidia",
    KERAS_BACKEND="torch",
    SL_CONNECTION_ID=CONNECTION_ID,
)

# Scale-to-zero: no idle workers; spin up on demand, retire after inactivity.
deployment.configure_autoscaling(
    cold_workers=int(os.environ.get("SL_COLD_WORKERS", "0")),
    max_workers=int(os.environ.get("SL_MAX_WORKERS", "2")),
    inactivity_timeout=int(os.environ.get("SL_INACTIVITY_TIMEOUT", "300")),
    target_util=0.9,  # sane defaults; not operator-tuned (keep config surface small)
    cold_mult=1,
)


async def _run(cmd: str) -> str:
    """Run a shell command, stream nothing, raise with output on failure."""
    proc = await asyncio.create_subprocess_shell(
        cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )
    out, _ = await proc.communicate()
    text = (out or b"").decode("utf-8", "replace")
    if proc.returncode != 0:
        raise RuntimeError(f"cmd failed ({proc.returncode}): {cmd}\n{text}")
    return text


async def _instance_status(instance_id: str) -> str:
    """Return the worker status message used by Vast to report Cloud Copy."""
    output = await _run(
        f"vastai show instance {shlex.quote(instance_id)} --raw --no-color"
    )
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid `vastai show instance --raw` output: {output}") from exc
    return str(payload.get("status_msg") or "").strip()


async def _wait_for_input(path: str, timeout: int, poll_interval: float) -> None:
    """Wait until a downloaded file/dir exists and its measured size is stable."""
    deadline = time.monotonic() + timeout
    previous_size = None
    stable_polls = 0
    while time.monotonic() < deadline:
        if os.path.exists(path):
            if os.path.isdir(path):
                size = sum(
                    os.path.getsize(os.path.join(root, name))
                    for root, _, files in os.walk(path)
                    for name in files
                )
            else:
                size = os.path.getsize(path)
            stable_polls = stable_polls + 1 if size == previous_size else 0
            previous_size = size
            if size > 0 and stable_polls >= 2:
                return
        await asyncio.sleep(poll_interval)
    raise TimeoutError(f"cloud download did not stabilize within {timeout}s: {path}")


async def _wait_for_cloud_copy(
    instance_id: str,
    previous_status: str,
    timeout: int,
    poll_interval: float,
) -> None:
    """Wait for a newly-started Vast Cloud Copy operation to finish."""
    deadline = time.monotonic() + timeout
    saw_transition = False
    last_status = previous_status
    while time.monotonic() < deadline:
        status = await _instance_status(instance_id)
        lowered = status.lower()
        if status != previous_status:
            saw_transition = True
        if any(marker in lowered for marker in ("failed", "error", "cancelled", "canceled")):
            raise RuntimeError(f"cloud copy failed: {status}")
        if saw_transition and "cloud copy operation finished" in lowered:
            return
        last_status = status
        await asyncio.sleep(poll_interval)
    raise TimeoutError(
        f"cloud copy did not report completion within {timeout}s; last status: {last_status!r}"
    )


def _safe_input_path(in_dir: str, input_name: str) -> str:
    """Resolve a worker-local relative input and reject path traversal."""
    path = PurePosixPath(input_name)
    if not input_name or path.is_absolute() or ".." in path.parts:
        raise ValueError("input_name must be a non-empty relative path without '..'")
    return f"{in_dir}/{path.as_posix()}"


@deployment.remote(benchmark_dataset=[{}], benchmark_runs=3)
async def benchmark() -> dict:
    """Small GPU benchmark required by the Vast Serverless autoscaler."""
    import torch

    x = torch.ones((512, 512), device="cuda")
    _ = x @ x
    torch.cuda.synchronize()
    return {"ok": True}


@deployment.remote()
async def extract(
    input_name: str,
    drive_src: str,
    drive_dst: str,
    detector: str = "retinaface",
    aligner: str = "hrnet",
    extract_size: int = 512,
    extract_norm: str = "hist",
    dedupe_threshold: int = 6,
) -> dict:
    """Extract faces from one media file pulled from Drive, push faces back to Drive.

    drive_src: Drive path of the input dir holding `input_name` (video or frame dir).
    drive_dst: Drive path to receive the extracted faces.
    """
    instance_id = os.environ.get("CONTAINER_ID", "")
    conn = os.environ.get("SL_CONNECTION_ID", "")
    # Assert scoped key is present (injected by Vast account env); never log the value.
    if not os.environ.get("VAST_API_KEY"):
        raise RuntimeError(
            "VAST_API_KEY is not set on worker — ensure the scoped cloud-copy key "
            "is stored as an encrypted Vast account environment variable "
            "(POST /api/v0/secrets/ with key=VAST_API_KEY)."
        )
    if not instance_id or not conn:
        raise RuntimeError(
            f"missing CONTAINER_ID={instance_id!r} or SL_CONNECTION_ID={conn!r} on worker"
        )

    job_root = f"{WORK_ROOT}/jobs/{uuid.uuid4().hex}"
    in_dir = f"{job_root}/in"
    faces_dir = f"{job_root}/faces"
    os.makedirs(in_dir, exist_ok=True)
    os.makedirs(faces_dir, exist_ok=True)

    def _copy(src: str, dst: str, direction: str) -> str:
        # shlex.quote every interpolated value: filenames/paths may contain spaces
        # or shell metacharacters that would otherwise break or inject the command.
        return (
            f"vastai cloud copy --src {shlex.quote(src)} --dst {shlex.quote(dst)} "
            f"--instance {shlex.quote(instance_id)} --connection {shlex.quote(conn)} "
            f"--transfer {shlex.quote(direction)}"
        )

    input_path = _safe_input_path(in_dir, input_name)

    # 1. Drive -> worker (input media). The CLI only starts an asynchronous
    # transfer, so wait for the requested object to arrive and stabilize.
    previous_status = await _instance_status(instance_id)
    await _run(_copy(drive_src, in_dir, "Cloud To Instance"))
    await _wait_for_cloud_copy(
        instance_id,
        previous_status,
        TRANSFER_TIMEOUT,
        TRANSFER_POLL_INTERVAL,
    )
    await _wait_for_input(input_path, TRANSFER_TIMEOUT, TRANSFER_POLL_INTERVAL)

    # 2. Extract faces on GPU.
    extract_cmd = (
        f"cd {shlex.quote(FACESWAP_DIR)} && python faceswap.py extract "
        f"-i {shlex.quote(input_path)} -o {shlex.quote(faces_dir)} "
        f"-D {shlex.quote(detector)} -A {shlex.quote(aligner)} "
        f"-z {int(extract_size)} -O {shlex.quote(extract_norm)}"
    )
    extract_log = await _run(extract_cmd)

    # 3. Optional dedupe (mirrors local dHash thinning).
    if dedupe_threshold and int(dedupe_threshold) > 0:
        deduped = f"{job_root}/faces_deduped"
        await _run(
            f"SRC={shlex.quote(faces_dir)} OUT={shlex.quote(deduped)} "
            f"THRESH={int(dedupe_threshold)} python {shlex.quote(DEDUPE_REMOTE)}"
        )
        faces_dir = deduped

    count = len([f for f in os.listdir(faces_dir) if f.lower().endswith(".png")])

    # 4. worker -> Drive (extracted faces) — skip if nothing extracted.
    if count > 0:
        previous_status = await _instance_status(instance_id)
        await _run(_copy(faces_dir, drive_dst, "Instance To Cloud"))
        await _wait_for_cloud_copy(
            instance_id,
            previous_status,
            TRANSFER_TIMEOUT,
            TRANSFER_POLL_INTERVAL,
        )
    shutil.rmtree(job_root, ignore_errors=True)

    return {
        "ok": count > 0,  # zero faces = soft failure (bad input / no detections)
        "input": input_name,
        "faces": count,
        "drive_dst": drive_dst if count > 0 else None,
        "log_tail": extract_log[-500:],
    }


# --- CLI --------------------------------------------------------------------

def _deploy() -> None:
    deployment.ensure_ready()
    print(f"deployed endpoint '{DEPLOYMENT_NAME}'")


def _submit(a: argparse.Namespace) -> None:
    # Deployment objects do not reconnect across processes. ensure_ready() is
    # required in this submit process; unchanged deployments use Vast's Tier 0.
    deployment.ensure_ready()
    result = asyncio.run(
        extract(
            input_name=a.input,
            drive_src=a.drive_src,
            drive_dst=a.drive_dst,
            detector=a.detector,
            aligner=a.aligner,
            extract_size=a.extract_size,
            extract_norm=a.extract_norm,
            dedupe_threshold=a.dedupe_threshold,
        )
    )
    print(json.dumps(result, indent=2))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="mode", required=True)
    sub.add_parser("deploy", help="provision/refresh the endpoint")

    s = sub.add_parser("submit", help="send an extract job")
    s.add_argument("--input", required=True, help="media filename inside drive_src")
    s.add_argument("--drive-src", dest="drive_src", required=True)
    s.add_argument("--drive-dst", dest="drive_dst", required=True)
    s.add_argument("--detector", default="retinaface")
    s.add_argument("--aligner", default="hrnet")
    s.add_argument("--extract-size", dest="extract_size", type=int, default=512)
    s.add_argument("--extract-norm", dest="extract_norm", default="hist")
    s.add_argument("--dedupe-threshold", dest="dedupe_threshold", type=int, default=6)

    a = p.parse_args()
    if a.mode == "deploy":
        _deploy()
    else:
        _submit(a)


if __name__ == "__main__":
    main()
