import importlib.util
import json
import os
import subprocess
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "app" / "rclone_runtime.py"
SPEC = importlib.util.spec_from_file_location("app_rclone_runtime", MODULE_PATH)
rclone_runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rclone_runtime)


class RcloneRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, {"GDRIVE_REMOTE": "gdrive"}, clear=False)
        self.env.start()
        rclone_runtime._reset_for_tests()

    def tearDown(self):
        rclone_runtime._reset_for_tests()
        self.env.stop()

    @mock.patch.object(rclone_runtime.shutil, "which", return_value=None)
    def test_missing_binary_has_actionable_error(self, _which):
        with self.assertRaisesRegex(RuntimeError, "app/Dockerfile"):
            rclone_runtime.ensure_ready()

    @mock.patch.object(rclone_runtime.shutil, "which", return_value="/usr/bin/rclone")
    @mock.patch.object(rclone_runtime.subprocess, "run")
    def test_native_rclone_remote_is_reused(self, run, _which):
        run.return_value = subprocess.CompletedProcess([], 0, stdout="gdrive:\n", stderr="")
        with mock.patch.dict(os.environ, {"GDRIVE_TOKEN_JSON": ""}, clear=False):
            self.assertEqual(rclone_runtime.ensure_ready(), "/usr/bin/rclone")
        run.assert_called_once_with(
            ["/usr/bin/rclone", "listremotes"],
            capture_output=True,
            text=True,
        )

    @mock.patch.object(rclone_runtime.shutil, "which", return_value="/usr/bin/rclone")
    @mock.patch.object(rclone_runtime.subprocess, "run")
    def test_oauth_token_cached_on_second_call(self, run, _which):
        token = json.dumps({"access_token": "a", "refresh_token": "r"})
        with mock.patch.dict(os.environ, {"GDRIVE_TOKEN_JSON": token}, clear=False):
            rclone_runtime.ensure_ready()
            rclone_runtime.ensure_ready()
        run.assert_not_called()

    @mock.patch.object(rclone_runtime.shutil, "which", return_value="/usr/bin/rclone")
    @mock.patch.object(rclone_runtime.subprocess, "run")
    def test_oauth_token_configures_env(self, run, _which):
        token = json.dumps({"access_token": "access", "refresh_token": "refresh"})
        with mock.patch.dict(
            os.environ,
            {
                "GDRIVE_TOKEN_JSON": token,
                "GDRIVE_ROOT_FOLDER_ID": "folder-123",
            },
            clear=False,
        ):
            rclone_runtime.ensure_ready()
            run.assert_not_called()
            self.assertEqual(os.environ["RCLONE_CONFIG_GDRIVE_TYPE"], "drive")
            self.assertEqual(os.environ["RCLONE_CONFIG_GDRIVE_SCOPE"], "drive")
            self.assertEqual(
                json.loads(os.environ["RCLONE_CONFIG_GDRIVE_TOKEN"])["refresh_token"],
                "refresh",
            )
            self.assertEqual(
                os.environ["RCLONE_CONFIG_GDRIVE_ROOT_FOLDER_ID"],
                "folder-123",
            )

    @mock.patch.object(rclone_runtime.shutil, "which", return_value="/usr/bin/rclone")
    @mock.patch.object(rclone_runtime.subprocess, "run")
    def test_missing_remote_has_actionable_error(self, run, _which):
        run.return_value = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.dict(os.environ, {"GDRIVE_TOKEN_JSON": ""}, clear=False):
            with self.assertRaisesRegex(RuntimeError, "gdrive-setup"):
                rclone_runtime.ensure_ready()


if __name__ == "__main__":
    unittest.main()
