"""rclone discovery and Google Drive remote setup for the Gradio app."""

import json
import os
import shutil
import subprocess
import threading


_setup_lock = threading.Lock()
_ready_key: tuple[str, ...] | None = None


def remote_name() -> str:
    return os.environ.get("GDRIVE_REMOTE", "gdrive")


def remote_path(path: str) -> str:
    return f"{remote_name()}:{path}"


def _find_binary() -> str:
    configured = os.environ.get("RCLONE_BINARY", "rclone")
    binary = shutil.which(configured)
    if binary:
        return binary
    raise RuntimeError(
        "rclone is not installed or is not in PATH. "
        "Run the app with app/Dockerfile, or install rclone on the host first."
    )


def _oauth_token() -> str:
    token_json = os.environ.get("GDRIVE_TOKEN_JSON", "").strip()
    if not token_json:
        return ""
    try:
        token = json.loads(token_json)
    except json.JSONDecodeError as exc:
        raise RuntimeError("GDRIVE_TOKEN_JSON is not valid JSON.") from exc
    if not token.get("access_token") or not token.get("refresh_token"):
        raise RuntimeError(
            "GDRIVE_TOKEN_JSON must contain access_token and refresh_token. "
            "Run 'make gdrive-setup' to authorize Google Drive again."
        )
    return json.dumps(token, separators=(",", ":"))


def _configure_oauth_env(remote: str, token_json: str) -> None:
    if not remote.replace("_", "").isalnum():
        raise RuntimeError(
            "GDRIVE_REMOTE must contain only letters, digits, or underscores "
            "when using OAuth environment configuration."
        )
    prefix = f"RCLONE_CONFIG_{remote.upper()}"
    os.environ[f"{prefix}_TYPE"] = "drive"
    os.environ[f"{prefix}_SCOPE"] = "drive"
    os.environ[f"{prefix}_TOKEN"] = token_json
    root_folder_id = os.environ.get("GDRIVE_ROOT_FOLDER_ID", "").strip()
    if root_folder_id:
        os.environ[f"{prefix}_ROOT_FOLDER_ID"] = root_folder_id


def ensure_ready() -> str:
    """Return the rclone binary after ensuring the configured remote exists."""
    global _ready_key

    binary = _find_binary()
    remote = remote_name()
    token_json = _oauth_token()
    key = (binary, remote, "oauth" if token_json else "configured")
    if _ready_key == key:
        return binary

    with _setup_lock:
        if _ready_key == key:
            return binary

        # Priority 1: env var token (Docker / RunPod workers)
        if token_json:
            _configure_oauth_env(remote, token_json)
            _ready_key = key
            return binary

        # Priority 2: native rclone config (local dev after `make gdrive-setup`)
        listed = subprocess.run(
            [binary, "listremotes"],
            capture_output=True,
            text=True,
        )
        if listed.returncode == 0 and f"{remote}:" in listed.stdout.splitlines():
            _ready_key = key
            return binary

        raise RuntimeError(
            f"Google Drive remote '{remote}:' is not configured. "
            "Run 'make gdrive-setup' to authorize, or set GDRIVE_TOKEN_JSON for Docker/RunPod."
        )


def run(args: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run rclone after validating the binary and Drive remote."""
    return subprocess.run([ensure_ready(), *args], **kwargs)


def _reset_for_tests() -> None:
    global _ready_key
    _ready_key = None
