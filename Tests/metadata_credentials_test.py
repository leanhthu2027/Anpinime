import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


class MetadataPreparationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.target = Path(self.folder.name) / "MetadataCredentials.plist"
        self.script = Path(__file__).resolve().parents[1] / "Tools/prepare-metadata-credentials.py"
        self.environment = {k: v for k, v in os.environ.items()
                            if k not in ("TMDB_READ_TOKEN", "TMDB_API_KEY")}

    def run_script(self, **settings):
        result = subprocess.run([sys.executable, str(self.script), "--output", str(self.target)],
                                env=dict(self.environment, **settings), capture_output=True, text=True)
        for value in settings.values():
            if value:
                self.assertNotIn(value, result.stdout + result.stderr)
        return result

    def test_private_default_and_repeatable_preparation(self):
        result = self.run_script(TMDB_API_KEY="a" * 32)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(plistlib.loads(self.target.read_bytes()), {"TMDB_API_KEY": "a" * 32})
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        before = self.target.read_bytes()
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.target.read_bytes(), before)

    def test_invalid_secret_preserves_existing_valid_resource(self):
        self.assertEqual(self.run_script(TMDB_API_KEY="b" * 32).returncode, 0)
        before = self.target.read_bytes()
        self.assertNotEqual(self.run_script(TMDB_API_KEY="bad-short-value").returncode, 0)
        self.assertEqual(self.target.read_bytes(), before)

    def test_missing_resource_fails_before_packaging(self):
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build secret", result.stderr)
        self.assertFalse(self.target.exists())

    def test_read_token_priority_and_no_value_in_logs(self):
        self.assertEqual(self.run_script(TMDB_READ_TOKEN="fixture-read-token", TMDB_API_KEY="c" * 32).returncode, 0)
        self.assertEqual(plistlib.loads(self.target.read_bytes()), {"TMDB_READ_TOKEN": "fixture-read-token"})


if __name__ == "__main__":
    unittest.main()
