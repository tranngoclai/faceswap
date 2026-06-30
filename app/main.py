#!/usr/bin/env python3
"""Gradio UI: upload a video, call the RunPod serverless extract endpoint.

Flow:
  1. User uploads a video file via the browser.
  2. App uploads it to Cloudflare R2 via boto3 S3-compatible API.
  3. App POSTs to the RunPod /runsync endpoint and waits for the result.
  4. Result (face count, R2 output path, raw JSON, face thumbnails) shown in UI.

Environment variables are loaded from app/.env (see .env.example).
"""
import json
import os
import shutil
import tempfile
import uuid
from pathlib import Path

import boto3
from botocore.config import Config
from dotenv import load_dotenv
import gradio as gr
import requests

# Load .env from the same directory as this file
load_dotenv(Path(__file__).parent / ".env")

# Maximum face thumbnails to download for preview
MAX_PREVIEW_FACES = 12

# --- Config from env --------------------------------------------------------

def _cfg(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


# --- R2 client --------------------------------------------------------------

def _r2_client():
    """Create a boto3 S3 client configured for Cloudflare R2."""
    return boto3.client(
        "s3",
        endpoint_url=_cfg("R2_ENDPOINT_URL"),
        aws_access_key_id=_cfg("R2_ACCESS_KEY_ID"),
        aws_secret_access_key=_cfg("R2_SECRET_ACCESS_KEY"),
        config=Config(signature_version="s3v4"),
        region_name="auto",
    )


# --- Helpers ----------------------------------------------------------------

def _r2_upload(local_path: str, r2_key: str, r2_bucket: str) -> None:
    """Upload a local file to R2. Raises on failure."""
    _r2_client().upload_file(local_path, r2_bucket, r2_key)


def _r2_list(r2_path: str, r2_bucket: str) -> list[str]:
    """List files under r2:<bucket>/<r2_path>, return relative filenames."""
    client = _r2_client()
    prefix = r2_path.rstrip("/") + "/"
    paginator = client.get_paginator("list_objects_v2")
    keys = []
    for page in paginator.paginate(Bucket=r2_bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            relative = obj["Key"][len(prefix):]
            if relative:
                keys.append(relative)
    return keys


def _r2_download_sample(r2_path: str, r2_bucket: str, local_dir: str, limit: int) -> list[str]:
    """Download up to `limit` PNG files from R2 into local_dir. Returns local paths."""
    files = [f for f in _r2_list(r2_path, r2_bucket) if f.lower().endswith(".png")][:limit]
    client = _r2_client()
    prefix = r2_path.rstrip("/") + "/"
    local_paths = []
    for fname in files:
        local = os.path.join(local_dir, fname)
        try:
            client.download_file(r2_bucket, prefix + fname, local)
            local_paths.append(local)
        except Exception:
            pass
    return local_paths


def _submit_job(payload: dict, timeout: int) -> dict:
    """POST to RunPod /runsync and return the parsed JSON response."""
    api_key = _cfg("RUNPOD_API_KEY")
    endpoint_id = _cfg("RUNPOD_ENDPOINT_ID")
    api_base = _cfg("RUNPOD_API_BASE", "https://api.runpod.ai/v2")
    url = f"{api_base}/{endpoint_id}/runsync"
    resp = requests.post(
        url,
        json=payload,
        headers={"Authorization": f"Bearer {api_key}"},
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()


# --- Core extract function --------------------------------------------------

def run_extract(
    video_file,
    detector: str,
    aligner: str,
    extract_size: int,
    extract_norm: str,
    dedupe_threshold: int,
    timeout: int,
):
    """Upload video to R2, submit extract job, yield (status, summary, raw_json, gallery)."""
    if video_file is None:
        yield ("Error", "Please upload a video file first.", "", [])
        return

    api_key = _cfg("RUNPOD_API_KEY")
    endpoint_id = _cfg("RUNPOD_ENDPOINT_ID")
    r2_bucket = _cfg("R2_BUCKET", "faceswap")

    if not api_key:
        yield ("Error", "RUNPOD_API_KEY is not set in .env.", "", [])
        return
    if not endpoint_id:
        yield ("Error", "RUNPOD_ENDPOINT_ID is not set in .env.", "", [])
        return

    video_path = video_file if isinstance(video_file, str) else video_file.name
    filename = Path(video_path).name
    job_id = uuid.uuid4().hex[:12]

    r2_src = f"uploads/{job_id}"
    r2_dst = f"faces/{job_id}"
    r2_key = f"{r2_src}/{filename}"

    try:
        yield ("Uploading", f"Uploading {filename} to R2 ({r2_key})…", "", [])
        _r2_upload(video_path, r2_key, r2_bucket)

        yield ("Running", "Video uploaded. Submitting extract job to RunPod…", "", [])
        payload = {
            "input": {
                "input_name": filename,
                "r2_src": r2_src,
                "r2_dst": r2_dst,
                "detector": detector,
                "aligner": aligner,
                "extract_size": extract_size,
                "extract_norm": extract_norm,
                "dedupe_threshold": dedupe_threshold,
            }
        }
        result = _submit_job(payload, timeout)
        raw = json.dumps(result, indent=2)

        output = result.get("output", {})
        if not isinstance(output, dict):
            yield ("Error", "Unexpected response format.", raw, [])
            return

        ok = output.get("ok", False)
        faces = output.get("faces", 0)
        out_path = output.get("r2_dst")

        if not ok:
            yield ("No faces", f"⚠ No faces detected in {filename}. Check your video.", raw, [])
            return

        yield ("Downloading previews", f"✓ {faces} face(s) extracted. Fetching previews…", raw, [])
        with tempfile.TemporaryDirectory() as tmp:
            previews = _r2_download_sample(out_path, r2_bucket, tmp, MAX_PREVIEW_FACES)
            persist_dir = tempfile.mkdtemp(prefix="fs_faces_")
            kept = []
            for p in previews:
                dst = os.path.join(persist_dir, os.path.basename(p))
                shutil.copy2(p, dst)
                kept.append(dst)

        summary = f"✓ Extracted {faces} face(s) → R2: {out_path}"
        if kept:
            summary += f"\nShowing {len(kept)} of {faces} face(s) below."
        yield ("Done", summary, raw, kept)

    except Exception as exc:
        yield ("Error", f"Failed: {exc}", "", [])


# --- Gradio UI --------------------------------------------------------------

with gr.Blocks(title="FaceSwap Extract") as demo:
    gr.Markdown("## FaceSwap — Serverless Extract")
    gr.Markdown(
        "Upload a video, configure extraction options, then click **Extract**. "
        "The video is uploaded to R2 and processed on a RunPod GPU worker."
    )

    with gr.Row():
        with gr.Column(scale=1):
            video_input = gr.Video(
                label="Input Video",
                sources=["upload"],
                height=360,
                width=640,
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
    demo.launch(share=False, theme=gr.themes.Soft())
