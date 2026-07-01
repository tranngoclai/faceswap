#!/usr/bin/env python3
"""Gradio UI: upload a video, call the RunPod serverless extract endpoint.

Flow:
  1. User uploads a video file via the browser.
  2. App uploads it to Cloudflare R2 via rclone subprocess.
  3. App POSTs to the RunPod /runsync endpoint and waits for the result.
  4. Result (face count, R2 output path, raw JSON, face thumbnails) shown in UI.

Environment variables are loaded from app/.env (see .env.example).
R2 credentials are configured via RCLONE_CONFIG_R2_* env vars.
"""
import os
from pathlib import Path

from dotenv import load_dotenv
import gradio as gr

load_dotenv(Path(__file__).parent / ".env")

from extract import MAX_PREVIEW_FACES, run_extract


def _cfg(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


with gr.Blocks(title="FaceSwap Extract") as demo:
    gr.Markdown("## FaceSwap — Serverless Extract")
    gr.Markdown(
        "Upload a video, set workspace name and side, then click **Extract**. "
        "The video is uploaded to Cloudflare R2 and processed on a RunPod GPU worker."
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
