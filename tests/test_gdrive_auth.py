import importlib.util
import json
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "gdrive_auth.py"
SPEC = importlib.util.spec_from_file_location("gdrive_auth", MODULE_PATH)
gdrive_auth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gdrive_auth)


class GdriveAuthTest(unittest.TestCase):
    def test_extract_token_returns_compact_refreshable_json(self):
        output = "notice\n" + json.dumps({
            "access_token": "access",
            "refresh_token": "refresh",
            "token_type": "Bearer",
        }) + "\nend"

        token = json.loads(gdrive_auth._extract_token(output))

        self.assertEqual(token["access_token"], "access")
        self.assertEqual(token["refresh_token"], "refresh")

    def test_extract_token_raises_when_no_refresh_token(self):
        output = json.dumps({"access_token": "access"})
        with self.assertRaises(RuntimeError):
            gdrive_auth._extract_token(output)

    def test_extract_token_raises_when_no_json(self):
        with self.assertRaises(RuntimeError):
            gdrive_auth._extract_token("no json here")


if __name__ == "__main__":
    unittest.main()
