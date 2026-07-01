#!/usr/bin/env python3
"""Authorize rclone Google Drive OAuth and store the remote in ~/.config/rclone/rclone.conf.

Usage:
    python3 scripts/gdrive_auth.py [remote-name]

Environment:
    GDRIVE_REMOTE        rclone remote name (default: gdrive)
    GDRIVE_ROOT_FOLDER_ID  restrict remote to this Drive folder ID (optional)
    RCLONE_BINARY        path to rclone binary (default: rclone)
"""

import json
import os
import shutil
import subprocess
import sys


def _extract_token(output: str) -> str:
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            token = json.loads(line)
        except json.JSONDecodeError:
            continue
        if token.get("access_token") and token.get("refresh_token"):
            return json.dumps(token, separators=(",", ":"))
    raise RuntimeError("rclone authorization did not return a refreshable OAuth token.")


def main() -> int:
    remote = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GDRIVE_REMOTE", "gdrive")
    root_folder_id = os.environ.get("GDRIVE_ROOT_FOLDER_ID", "").strip()

    binary = shutil.which(os.environ.get("RCLONE_BINARY", "rclone"))
    if not binary:
        raise RuntimeError("rclone not found. Install with 'brew install rclone'.")

    print("Opening Google OAuth in your browser...", flush=True)
    result = subprocess.run(
        [binary, "authorize", "drive"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "see rclone output above"
        raise RuntimeError(f"Google OAuth authorization failed: {detail}")

    token_json = _extract_token(result.stdout)

    args = [binary, "config", "create", remote, "drive", "scope=drive", f"token={token_json}"]
    if root_folder_id:
        args.append(f"root_folder_id={root_folder_id}")

    configured = subprocess.run(args, capture_output=True, text=True)
    if configured.returncode != 0:
        detail = configured.stderr.strip() or configured.stdout.strip()
        raise RuntimeError(f"Failed to create rclone remote '{remote}': {detail}")

    print(f"Google Drive remote '{remote}' saved to ~/.config/rclone/rclone.conf.")
    if root_folder_id:
        print(f"Root folder: {root_folder_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
