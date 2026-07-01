"""Unit tests for the RunPod serverless extractor without the runpod SDK."""
import importlib.util
import json
import os
import sys
import types
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch


# Stub the runpod SDK so the module imports without it installed. _serve() calls
# runpod.serverless.start(); tests exercise handler() directly, so start is a no-op.
runpod_mod = types.ModuleType("runpod")
serverless_mod = types.ModuleType("runpod.serverless")


def _fake_start(config):
    return None


serverless_mod.start = _fake_start
runpod_mod.serverless = serverless_mod
sys.modules.setdefault("runpod", runpod_mod)
sys.modules.setdefault("runpod.serverless", serverless_mod)

# Stub `requests` so _submit imports cleanly without the package installed; the
# POST test patches requests.post on this stub.
requests_mod = types.ModuleType("requests")
requests_mod.post = MagicMock()
sys.modules.setdefault("requests", requests_mod)

SCRIPT = Path(__file__).parents[2] / "scripts" / "cloud" / "serverless_extract.py"
SPEC = importlib.util.spec_from_file_location("serverless_extract_under_test", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GDriveTransferTest(unittest.IsolatedAsyncioTestCase):
    async def test_gdrive_download_runs_rclone_copy(self):
        with patch.object(MODULE, "_run", AsyncMock(return_value="")) as mock_run:
            await MODULE._gdrive_download("extract/in/alice.mp4", "/job/in")
        mock_run.assert_awaited_once()
        cmd = mock_run.call_args[0][0]
        self.assertIn("rclone copy", cmd)
        self.assertIn("gdrive:", cmd)
        self.assertIn("/job/in", cmd)

    async def test_gdrive_upload_runs_rclone_copy(self):
        with patch.object(MODULE, "_run", AsyncMock(return_value="")) as mock_run:
            await MODULE._gdrive_upload("/job/faces", "extract/faces/alice")
        mock_run.assert_awaited_once()
        cmd = mock_run.call_args[0][0]
        self.assertIn("rclone copy", cmd)
        self.assertIn("gdrive:", cmd)
        self.assertIn("/job/faces", cmd)


class GDriveSetupTest(unittest.TestCase):
    def test_oauth_token_configures_environment_remote(self):
        token = json.dumps({"access_token": "access", "refresh_token": "refresh"})
        with patch.object(MODULE, "GDRIVE_TOKEN_JSON", token), \
                patch.object(MODULE, "GDRIVE_ROOT_FOLDER_ID", "folder-123"), \
                patch.dict(os.environ, {}, clear=False):
            MODULE._setup_gdrive()
            self.assertEqual(os.environ["RCLONE_CONFIG_GDRIVE_TYPE"], "drive")
            self.assertEqual(os.environ["RCLONE_CONFIG_GDRIVE_SCOPE"], "drive")
            self.assertEqual(os.environ["RCLONE_CONFIG_GDRIVE_ROOT_FOLDER_ID"], "folder-123")
            self.assertEqual(
                json.loads(os.environ["RCLONE_CONFIG_GDRIVE_TOKEN"])["refresh_token"],
                "refresh",
            )


class HandlerTest(unittest.IsolatedAsyncioTestCase):
    async def test_handler_passes_input_to_extract_async(self):
        fake_result = {"ok": True, "faces": 5}
        with patch.object(MODULE, "_extract_async", AsyncMock(return_value=fake_result)) as mock_extract:
            result = await MODULE.handler({"id": "job-1", "input": {
                "input_name": "alice.mp4",
                "gdrive_src": "extract/in",
                "gdrive_dst": "extract/faces",
            }})
        self.assertEqual(result, fake_result)
        mock_extract.assert_awaited_once()
        passed_input = mock_extract.call_args[0][0]
        self.assertEqual(passed_input["input_name"], "alice.mp4")


class SubmitLifecycleTest(unittest.TestCase):
    def _args(self):
        return Namespace(
            input="alice.mp4", gdrive_src="extract/in", gdrive_dst="extract/faces",
            detector="retinaface", aligner="hrnet", extract_size=512,
            extract_norm="hist", dedupe_threshold=6, timeout=600,
        )

    def test_submit_posts_to_runpod_api(self):
        mock_resp = MagicMock()
        mock_resp.json.return_value = {"status": "COMPLETED", "output": {"ok": True}}
        mock_resp.raise_for_status = lambda: None
        with patch.object(MODULE, "RUNPOD_API_KEY", "k"), \
                patch.object(MODULE, "RUNPOD_ENDPOINT_ID", "ep1"), \
                patch("requests.post", return_value=mock_resp) as mock_post:
            with redirect_stdout(StringIO()):
                MODULE._submit(self._args())
        mock_post.assert_called_once()
        url = mock_post.call_args[0][0]
        self.assertIn("runsync", url)
        self.assertIn("ep1", url)
        payload = mock_post.call_args.kwargs["json"]
        self.assertEqual(payload["input"]["input_name"], "alice.mp4")

    def test_submit_requires_api_key(self):
        with patch.object(MODULE, "RUNPOD_API_KEY", ""), \
                patch.object(MODULE, "RUNPOD_ENDPOINT_ID", "ep1"):
            with self.assertRaises(RuntimeError):
                MODULE._submit(self._args())

    def test_submit_requires_endpoint_id(self):
        with patch.object(MODULE, "RUNPOD_API_KEY", "k"), \
                patch.object(MODULE, "RUNPOD_ENDPOINT_ID", ""):
            with self.assertRaises(RuntimeError):
                MODULE._submit(self._args())


class InputValidationTest(unittest.TestCase):
    def test_accepts_nested_relative_input(self):
        self.assertEqual(
            MODULE._safe_input_path("/job/in", "frames/alice"),
            "/job/in/frames/alice",
        )

    def test_rejects_absolute_and_parent_paths(self):
        for value in ("/etc/passwd", "../secret", "frames/../../secret", ""):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    MODULE._safe_input_path("/job/in", value)


if __name__ == "__main__":
    unittest.main()
