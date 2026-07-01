#!/usr/bin/env python3
"""Gradio UI: upload a video, call the RunPod serverless extract endpoint.

Flow:
  1. User uploads a video file via the browser.
  2. App uploads it to Google Drive via rclone subprocess.
  3. App POSTs to the RunPod /runsync endpoint and waits for the result.
  4. Result (face count, Drive output path, raw JSON, face thumbnails) shown in UI.

Environment variables are loaded from app/.env (see .env.example).
Credential: the app configures rclone from GDRIVE_TOKEN_JSON, or reuses an
existing gdrive remote when running directly on a configured host.
"""
import json
import os
import shutil
import tempfile
from pathlib import Path

from dotenv import load_dotenv
import gradio as gr
import requests

# Load .env from the same directory as this file
load_dotenv(Path(__file__).parent / ".env")

import manifest
import rclone_runtime

# Maximum face thumbnails to download for preview
MAX_PREVIEW_FACES = 12

# --- Config from env --------------------------------------------------------

def _cfg(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


# --- rclone gdrive helpers --------------------------------------------------

def _gdrive_upload(local_path: str, gdrive_dest: str) -> None:
    """rclone copy <local_path> into gdrive:<gdrive_dest_dir>."""
    # rclone copy uploads a file into the destination directory
    dest_dir = gdrive_dest.rsplit("/", 1)[0] if "/" in gdrive_dest else gdrive_dest
    result = rclone_runtime.run(
        ["copy", local_path, rclone_runtime.remote_path(dest_dir), "-v"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"rclone upload failed: {result.stderr}")


def _gdrive_list(gdrive_path: str) -> list[str]:
    """List filenames under gdrive:<gdrive_path>, return relative filenames."""
    result = rclone_runtime.run(
        ["lsf", rclone_runtime.remote_path(gdrive_path), "--files-only"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"rclone list failed: {result.stderr}")
    return [f.strip() for f in result.stdout.splitlines() if f.strip()]


def _gdrive_download_sample(gdrive_path: str, local_dir: str, limit: int) -> list[str]:
    """Download up to `limit` PNG files from gdrive:<gdrive_path> into local_dir."""
    all_files = _gdrive_list(gdrive_path)
    png_files = [f for f in all_files if f.lower().endswith(".png")][:limit]
    if not png_files and not all_files:
        raise RuntimeError(
            f"No files found at Drive path '{gdrive_path}'. "
            "Verify the worker completed successfully and wrote to the correct path."
        )
    for fname in png_files:
        result = rclone_runtime.run(
            ["copy", rclone_runtime.remote_path(f"{gdrive_path}/{fname}"), local_dir, "-v"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            print(f"[preview] download failed for {fname}: {result.stderr}", flush=True)
    return [
        os.path.join(local_dir, f) for f in png_files
        if os.path.exists(os.path.join(local_dir, f))
    ]


def _submit_job(payload: dict, timeout: int) -> dict:
    """/runsync then poll /status if job is still IN_PROGRESS.

    RunPod's /runsync waits up to ~90s server-side. Longer jobs return
    IN_PROGRESS with a job ID; we then poll /status/{id} until COMPLETED/FAILED.
    """
    import time

    api_key = _cfg("RUNPOD_API_KEY")
    endpoint_id = _cfg("RUNPOD_ENDPOINT_ID")
    api_base = _cfg("RUNPOD_API_BASE", "https://api.runpod.ai/v2")
    headers = {"Authorization": f"Bearer {api_key}"}

    resp = requests.post(
        f"{api_base}/{endpoint_id}/runsync",
        json=payload,
        headers=headers,
        timeout=timeout,
    )
    resp.raise_for_status()
    result = resp.json()

    job_id = result.get("id")
    deadline = time.monotonic() + timeout
    poll_interval = 5
    while result.get("status") == "IN_PROGRESS" and job_id:
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Job {job_id} still IN_PROGRESS after {timeout}s")
        time.sleep(poll_interval)
        status_resp = requests.get(
            f"{api_base}/{endpoint_id}/status/{job_id}",
            headers=headers,
            timeout=30,
        )
        status_resp.raise_for_status()
        result = status_resp.json()

    return result


# --- Core extract function --------------------------------------------------

def run_extract(
    video_file,
    workspace_name: str,
    side: str,
    detector: str,
    aligner: str,
    extract_size: int,
    extract_norm: str,
    dedupe_threshold: int,
    timeout: int,
):
    """Upload video to Drive, submit extract job, yield (status, summary, raw_json, gallery)."""
    if video_file is None:
        yield ("Error", "Please upload a video file first.", "", [])
        return
    if not workspace_name.strip():
        yield ("Error", "Workspace name is required.", "", [])
        return
    if "/" in workspace_name or ".." in workspace_name:
        yield ("Error", "Workspace name must not contain '/' or '..'.", "", [])
        return
    if side not in ("A", "B"):
        yield ("Error", "Side must be A or B.", "", [])
        return

    api_key = _cfg("RUNPOD_API_KEY")
    endpoint_id = _cfg("RUNPOD_ENDPOINT_ID")

    if not api_key:
        yield ("Error", "RUNPOD_API_KEY is not set in .env.", "", [])
        return
    if not endpoint_id:
        yield ("Error", "RUNPOD_ENDPOINT_ID is not set in .env.", "", [])
        return

    video_path = video_file if isinstance(video_file, str) else video_file.name
    filename = Path(video_path).name
    ws = workspace_name.strip()

    gdrive_src = f"{ws}/source/{side}"
    gdrive_dst = f"{ws}/extract/{side}"
    gdrive_dest_file = f"{gdrive_src}/{filename}"

    try:
        yield ("Uploading", f"Uploading {filename} to Drive ({gdrive_dest_file})…", "", [])
        _gdrive_upload(video_path, gdrive_dest_file)
        manifest.record_source(ws, side, filename)

        yield ("Running", "Video uploaded. Submitting extract job to RunPod (polling until done)…", "", [])
        payload = {
            "input": {
                "input_name": filename,
                "gdrive_src": gdrive_src,
                "gdrive_dst": gdrive_dst,
                "detector": detector,
                "aligner": aligner,
                "extract_size": extract_size,
                "extract_norm": extract_norm,
                "dedupe_threshold": dedupe_threshold,
            }
        }
        result = _submit_job(payload, timeout)
        raw = json.dumps(result, indent=2)

        job_status = result.get("status")
        if job_status == "FAILED":
            error_msg = result.get("error", "Unknown worker error")
            yield ("Error", f"RunPod job failed: {error_msg}", raw, [])
            return
        if job_status not in ("COMPLETED", None):
            yield ("Error", f"RunPod job did not complete (status={job_status}). Check Raw Response.", raw, [])
            return

        output = result.get("output")
        if not isinstance(output, dict):
            yield ("Error", f"Unexpected output format (got {type(output).__name__}). Check Raw Response.", raw, [])
            return

        ok = output.get("ok", False)
        faces = output.get("faces", 0)
        out_path = output.get("gdrive_dst")

        if not ok:
            manifest.record_extract(ws, side, faces=0, gdrive_path=gdrive_dst)
            yield ("No faces", f"No faces detected in {filename} (worker returned ok=false, faces={faces}). Check Raw Response.", raw, [])
            return

        manifest.record_extract(ws, side, faces=faces, gdrive_path=gdrive_dst)
        yield ("Downloading previews", f"{faces} face(s) extracted. Fetching previews…", raw, [])
        with tempfile.TemporaryDirectory() as tmp:
            previews = _gdrive_download_sample(out_path, tmp, MAX_PREVIEW_FACES)
            persist_dir = tempfile.mkdtemp(prefix="fs_faces_")
            kept = []
            for p in previews:
                dst = os.path.join(persist_dir, os.path.basename(p))
                shutil.copy2(p, dst)
                kept.append(dst)

        summary = f"Extracted {faces} face(s) -> Drive: {out_path}"
        if kept:
            summary += f"\nShowing {len(kept)} of {faces} face(s) below."
        yield ("Done", summary, raw, kept)

    except Exception as exc:
        yield ("Error", f"Failed: {exc}", "", [])


# --- Gradio UI --------------------------------------------------------------

with gr.Blocks(title="FaceSwap Extract") as demo:
    gr.Markdown("## FaceSwap — Serverless Extract")
    gr.Markdown(
        "Upload a video, set workspace name and side, then click **Extract**. "
        "The video is uploaded to Google Drive and processed on a RunPod GPU worker."
    )

    with gr.Row():
        with gr.Column(scale=1):
            video_input = gr.Video(
                label="Input Video",
                sources=["upload"],
                height=360,
                width=640,
            )

            workspace_input = gr.Textbox(
                label="Workspace Name",
                placeholder="e.g. alice-bob-001",
                info="Unique name; reusing overwrites prior extract/train artifacts.",
            )
            side_input = gr.Radio(
                choices=["A", "B"],
                value="A",
                label="Side (A or B)",
            )

            with gr.Accordion("Advanced Options", open=False):
                detector = gr.Dropdown(
                    choices=["retinaface", "mtcnn", "cv2_dnn"],
                    value="retinaface",
                    label="Detector",
                )
                aligner = gr.Dropdown(
                    choices=["hrnet", "fan", "cv2_dnn"],
                    value="hrnet",
                    label="Aligner",
                )
                extract_size = gr.Slider(
                    minimum=128, maximum=1024, value=512, step=64,
                    label="Extract Size (px)",
                )
                extract_norm = gr.Dropdown(
                    choices=["hist", "mean", "none"],
                    value="hist",
                    label="Normalisation",
                )
                dedupe_threshold = gr.Slider(
                    minimum=0, maximum=20, value=6, step=1,
                    label="Dedupe Threshold (0 = disabled)",
                )
                timeout = gr.Number(
                    value=600, label="Request Timeout (s)", precision=0,
                )

            extract_btn = gr.Button("Extract", variant="primary")

        with gr.Column(scale=1):
            status_label = gr.Textbox(label="Status", interactive=False)
            summary_text = gr.Textbox(label="Summary", interactive=False, lines=3)
            raw_json = gr.Code(label="Raw Response", language="json", lines=10)

    face_gallery = gr.Gallery(
        label=f"Extracted Faces (up to {MAX_PREVIEW_FACES})",
        columns=6,
        rows=2,
        height=280,
        object_fit="contain",
        show_label=True,
    )

    extract_btn.click(
        fn=run_extract,
        inputs=[
            video_input,
            workspace_input,
            side_input,
            detector,
            aligner,
            extract_size,
            extract_norm,
            dedupe_threshold,
            timeout,
        ],
        outputs=[status_label, summary_text, raw_json, face_gallery],
    )


if __name__ == "__main__":
    demo.launch(
        share=False,
        theme=gr.themes.Soft(),
        server_name=_cfg("GRADIO_SERVER_NAME", "127.0.0.1"),
        server_port=int(_cfg("GRADIO_SERVER_PORT", "7860")),
    )
