#!/usr/bin/env python3
"""Workspace manifest.json — read/write helpers via rclone gdrive remote.

Manifest lives at gdrive:<workspace_name>/manifest.json.
Schema v1:
  {
    "schema_version": "1",
    "workspace_name": "<ws>",
    "updated_at": "<ISO8601>",
    "source": {
      "A": ["video.mp4"],       # source filenames uploaded for each side
      "B": []
    },
    "extract": {
      "A": {"faces": 42, "gdrive_path": "<ws>/extract/A", "updated_at": "..."},
      "B": null
    }
  }
"""
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone


GDRIVE_REMOTE = os.environ.get("GDRIVE_REMOTE", "gdrive")
MANIFEST_FILENAME = "manifest.json"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _remote_path(ws: str) -> str:
    return f"{GDRIVE_REMOTE}:{ws}/{MANIFEST_FILENAME}"


def read(ws: str) -> dict:
    """Return existing manifest for workspace, or a fresh empty one."""
    result = subprocess.run(
        ["rclone", "cat", _remote_path(ws)],
        capture_output=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return _empty(ws)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return _empty(ws)


def write(ws: str, data: dict) -> None:
    """Write manifest dict to gdrive:<ws>/manifest.json via a temp file."""
    data["updated_at"] = _now()
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, prefix="fs_manifest_"
    ) as fh:
        json.dump(data, fh, indent=2)
        tmp_path = fh.name
    try:
        result = subprocess.run(
            ["rclone", "copyto", tmp_path, _remote_path(ws)],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"manifest write failed: {result.stderr}")
    finally:
        os.unlink(tmp_path)


def record_source(ws: str, side: str, filename: str) -> None:
    """Add filename to source[side] list (deduped) and write back."""
    data = read(ws)
    existing = data.setdefault("source", {"A": [], "B": []})
    files = existing.setdefault(side, [])
    if filename not in files:
        files.append(filename)
    write(ws, data)


def record_extract(ws: str, side: str, faces: int, gdrive_path: str) -> None:
    """Record extract result for side and write back."""
    data = read(ws)
    data.setdefault("extract", {"A": None, "B": None})
    data["extract"][side] = {
        "faces": faces,
        "gdrive_path": gdrive_path,
        "updated_at": _now(),
    }
    write(ws, data)


def _empty(ws: str) -> dict:
    return {
        "schema_version": "1",
        "workspace_name": ws,
        "updated_at": _now(),
        "source": {"A": [], "B": []},
        "extract": {"A": None, "B": None},
    }
