#!/usr/bin/env python3
"""Workspace manifest.json — read/write helpers via rclone R2 remote.

Manifest lives at r2:<bucket>/<workspace_name>/manifest.json.
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
      "A": {"faces": 42, "r2_path": "<ws>/extract/A", "updated_at": "..."},
      "B": null
    }
  }
"""
import json
import os
import tempfile
from datetime import datetime, timezone

from r2 import r2_path, rclone

MANIFEST_FILENAME = "manifest.json"


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read(ws: str) -> dict:
    """Return existing manifest for workspace, or a fresh empty one."""
    result = rclone(
        ["cat", r2_path(f"{ws}/{MANIFEST_FILENAME}")],
        capture_output=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return _empty(ws)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return _empty(ws)


def write(ws: str, data: dict) -> None:
    """Write manifest dict to r2:<bucket>/<ws>/manifest.json via a temp file."""
    data["updated_at"] = _now()
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, prefix="fs_manifest_"
    ) as fh:
        json.dump(data, fh, indent=2)
        tmp_path = fh.name
    try:
        result = rclone(
            ["copyto", tmp_path, r2_path(f"{ws}/{MANIFEST_FILENAME}")],
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


def record_extract(ws: str, side: str, faces: int, r2_path: str) -> None:
    """Record extract result for side and write back."""
    data = read(ws)
    data.setdefault("extract", {"A": None, "B": None})
    data["extract"][side] = {
        "faces": faces,
        "r2_path": r2_path,
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
