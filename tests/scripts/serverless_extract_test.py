"""Unit tests for Serverless transfer polling without requiring the Vast SDK."""
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import AsyncMock, patch


class _Image:
    def __getattr__(self, _name):
        return lambda *args, **kwargs: self


class _Deployment:
    def __init__(self, *args, **kwargs):
        self.ready_calls = 0

    def image(self, *args, **kwargs):
        return _Image()

    def configure_autoscaling(self, **kwargs):
        return None

    def remote(self, *args, **kwargs):
        def decorator(func):
            return func

        return decorator

    def ensure_ready(self):
        self.ready_calls += 1


vastai = types.ModuleType("vastai")
serverless = types.ModuleType("vastai.serverless")
remote = types.ModuleType("vastai.serverless.remote")
remote.Deployment = _Deployment
sys.modules.setdefault("vastai", vastai)
sys.modules.setdefault("vastai.serverless", serverless)
sys.modules.setdefault("vastai.serverless.remote", remote)

SCRIPT = Path(__file__).parents[2] / "scripts" / "cloud" / "serverless_extract.py"
SPEC = importlib.util.spec_from_file_location("serverless_extract_under_test", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DownloadPollingTest(unittest.IsolatedAsyncioTestCase):
    async def test_wait_for_download_accepts_stable_nonempty_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "input.mp4")
            with open(path, "wb") as f:
                f.write(b"video")
            ok_status = AsyncMock(return_value="Cloud Copy Operation Complete")
            with patch.object(MODULE, "_instance_status", ok_status):
                await MODULE._wait_for_download("123", path, timeout=1, poll_interval=0.001)

    async def test_wait_for_download_times_out_for_missing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            ok_status = AsyncMock(return_value="Cloud Copy Operation Complete")
            with patch.object(MODULE, "_instance_status", ok_status):
                with self.assertRaises(TimeoutError) as ctx:
                    await MODULE._wait_for_download(
                        "123",
                        os.path.join(tmp, "missing.mp4"),
                        timeout=0.01,
                        poll_interval=0.001,
                    )
            self.assertIn("Check Drive path", str(ctx.exception))

    async def test_wait_for_download_raises_on_copy_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            fail_status = AsyncMock(return_value="Cloud Copy Failed: permission denied")
            with patch.object(MODULE, "_instance_status", fail_status):
                with self.assertRaisesRegex(RuntimeError, "permission denied"):
                    await MODULE._wait_for_download(
                        "123",
                        os.path.join(tmp, "input.mp4"),
                        timeout=1,
                        poll_interval=0.001,
                    )

    async def test_wait_for_download_raises_on_cancelled(self):
        with tempfile.TemporaryDirectory() as tmp:
            cancelled = AsyncMock(return_value="Cloud Copy Cancelled by user")
            with patch.object(MODULE, "_instance_status", cancelled):
                with self.assertRaises(RuntimeError):
                    await MODULE._wait_for_download(
                        "123",
                        os.path.join(tmp, "input.mp4"),
                        timeout=1,
                        poll_interval=0.001,
                    )


class UploadPollingTest(unittest.IsolatedAsyncioTestCase):
    async def test_wait_for_upload_returns_on_stable_complete(self):
        statuses = AsyncMock(
            side_effect=[
                "Cloud Copy In Progress",
                "Cloud Copy Operation Complete",
                "Cloud Copy Operation Complete",
            ]
        )
        with patch.object(MODULE, "_instance_status", statuses):
            await MODULE._wait_for_upload("123", timeout=1, poll_interval=0.001)
        self.assertEqual(statuses.await_count, 3)

    async def test_wait_for_upload_times_out_if_never_completes(self):
        with patch.object(
            MODULE, "_instance_status", AsyncMock(return_value="Cloud Copy In Progress")
        ):
            with self.assertRaises(TimeoutError):
                await MODULE._wait_for_upload("123", timeout=0.01, poll_interval=0.001)

    async def test_wait_for_upload_raises_on_failure(self):
        with patch.object(
            MODULE,
            "_instance_status",
            AsyncMock(return_value="Cloud Copy Failed: quota"),
        ):
            with self.assertRaisesRegex(RuntimeError, "quota"):
                await MODULE._wait_for_upload("123", timeout=1, poll_interval=0.001)


class InstanceStatusTest(unittest.IsolatedAsyncioTestCase):
    async def test_instance_status_parses_raw_json(self):
        with patch.object(
            MODULE,
            "_run",
            AsyncMock(return_value='{"status_msg": "Cloud Copy Started"}'),
        ):
            self.assertEqual(
                await MODULE._instance_status("123"), "Cloud Copy Started"
            )


class SubmitLifecycleTest(unittest.TestCase):
    def test_deploy_calls_ensure_ready(self):
        before = MODULE.deployment.ready_calls
        MODULE._deploy()
        self.assertEqual(MODULE.deployment.ready_calls, before + 1)

    def test_submit_calls_ensure_ready_before_remote_function(self):
        args = Namespace(
            input="alice.mp4",
            drive_src="faceswap-extract/in",
            drive_dst="faceswap-extract/faces",
            detector="retinaface",
            aligner="hrnet",
            extract_size=512,
            extract_norm="hist",
            dedupe_threshold=6,
        )
        before = MODULE.deployment.ready_calls
        with patch.object(MODULE, "extract", AsyncMock(return_value={"ok": True})):
            with redirect_stdout(StringIO()):
                MODULE._submit(args)
        self.assertEqual(MODULE.deployment.ready_calls, before + 1)


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
