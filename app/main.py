#!/usr/bin/env python3
"""Gradio UI: upload a video, call the RunPod serverless extract endpoint.

Flow:
  1. User uploads a video file via the browser.
  2. App uploads it to Cloudflare R2 via rclone (using env-var credentials).
  3. App POSTs to the RunPod /runsync endpoint and waits for the result.
  4. Result (face count, R2 output path, raw JSON) is shown in the UI.

Environment variables are loaded from app/.env (see .env.example).
"""
import json
import os
import shlex
import subprocess
import uuid
from pathlib import Path

from dotenv import load_dotenv
import gradio as gr
import requests

# Load .env from the same directory as this file
load_dotenv(Path(__file__).parent / ".env")

# --- Config from env --------------------------------------------------------

def _cfg(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


# --- Helpers ----------------------------------------------------------------

def _r2_upload(local_path: str, r2_key: str, r2_bucket: str) -> None:
    """Upload a local file to R2 via rclone. Raises on failure."""
    remote = f"r2:{r2_bucket}/{r2_key}"
    cmd = f"rclone copyto {shlex.quote(local_path)} {shlex.quote(remote)} -v"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"rclone upload failed (exit {result.returncode}):\n"
            f"{result.stdout}\n{result.stderr}"
        )


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
    """Upload video to R2, submit extract job, yield (status, summary, raw_json)."""
    if video_file is None:
        yield "Error", "Please upload a video file first.", ""
        return

    api_key = _cfg("RUNPOD_API_KEY")
    endpoint_id = _cfg("RUNPOD_ENDPOINT_ID")
    r2_bucket = _cfg("R2_BUCKET", "faceswap")

    if not api_key:
        yield "Error", "RUNPOD_API_KEY is not set in .env.", ""
        return
    if not endpoint_id:
        yield "Error", "RUNPOD_ENDPOINT_ID is not set in .env.", ""
        return

    video_path = video_file if isinstance(video_file, str) else video_file.name
    filename = Path(video_path).name
    job_id = uuid.uuid4().hex[:12]

    r2_src = f"uploads/{job_id}"
    r2_dst = f"faces/{job_id}"
    r2_key = f"{r2_src}/{filename}"

    try:
        yield "Uploading", f"Uploading {filename} to R2 ({r2_key})…", ""
        _r2_upload(video_path, r2_key, r2_bucket)

        yield "Running", "Video uploaded. Submitting extract job to RunPod…", ""
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
        if isinstance(output, dict):
            ok = output.get("ok", False)
            faces = output.get("faces", 0)
            out_path = output.get("r2_dst", "—")
            if ok:
                yield "Done", f"✓ Extracted {faces} face(s) → R2: {out_path}", raw
            else:
                yield "No faces", f"⚠ No faces detected in {filename}. Check your video.", raw
        else:
            yield "Error", "Unexpected response format.", raw

    except Exception as exc:
        yield "Error", f"Failed: {exc}", ""


# --- Gradio UI --------------------------------------------------------------

with gr.Blocks(title="FaceSwap Extract", theme=gr.themes.Soft()) as demo:
    gr.Markdown("## FaceSwap — Serverless Extract")
    gr.Markdown(
        "Upload a video, configure extraction options, then click **Extract**. "
        "The video is uploaded to R2 and processed on a RunPod GPU worker."
    )

    with gr.Row():
        with gr.Column(scale=1):
            video_input = gr.Video(label="Input Video", sources=["upload"])

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
            raw_json = gr.Code(label="Raw Response", language="json", lines=15)

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
        outputs=[status_label, summary_text, raw_json],
    )


if __name__ == "__main__":
    demo.launch(share=False)
