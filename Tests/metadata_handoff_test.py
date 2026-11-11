#!/usr/bin/env python3
"""Offline checks of the encrypted Actions handoff, using synthetic keys."""

import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("handoff", Path(__file__).resolve().parents[1]
                                            / "Tools/metadata-credential-handoff.py")
handoff = importlib.util.module_from_spec(spec)
spec.loader.exec_module(handoff)


class HandoffTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="anpinime-handoff-test-")
        cls.directory = Path(cls.temporary.name) / "runner"
        cls.ctx = handoff.context({"GITHUB_REPOSITORY": "example/test", "GITHUB_SHA": "a" * 40,
                                   "GITHUB_RUN_ID": "12345", "GITHUB_RUN_ATTEMPT": "1"})
        cls.now = 1000
        cls.request = handoff.create(cls.directory, cls.ctx, now=cls.now)
        cls.config = {"TMDB_API_KEY": "0123456789abcdef" * 2}
        cls.packet = handoff.encrypt(cls.request, cls.ctx, cls.config,
                                     Path(cls.temporary.name) / "public.pem", now=cls.now)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_real_oaep_roundtrip(self):
        self.assertEqual(handoff.decrypt(self.directory, self.packet, self.ctx, now=self.now), self.config)

    def test_public_request_and_ciphertext_do_not_contain_credential_or_private_key(self):
        public = json.dumps(self.request) + json.dumps(self.packet)
        self.assertNotIn(self.config["TMDB_API_KEY"], public)
        self.assertNotIn("PRIVATE KEY", public)
        self.assertEqual((self.directory / "private.pem").stat().st_mode & 0o777, 0o600)

    def test_different_build_and_run_attempt_rejected(self):
        for field, value in [("sourceCommit", "b" * 40), ("runID", "12346"), ("runAttempt", "2"),
                             ("repository", "other/test"), ("requestID", "0" * 32)]:
            with self.subTest(field=field), self.assertRaises(handoff.HandoffError):
                handoff.decrypt(self.directory, dict(self.packet, **{field: value}), self.ctx, now=self.now)

    def test_corrupt_ciphertext_rejected(self):
        ciphertext = bytearray(base64.b64decode(self.packet["ciphertext"]))
        ciphertext[100] ^= 1
        packet = dict(self.packet, ciphertext=base64.b64encode(ciphertext).decode())
        with self.assertRaises(handoff.HandoffError):
            handoff.decrypt(self.directory, packet, self.ctx, now=self.now)

    def test_plaintext_binding_checked_after_decrypt(self):
        malicious = {"v": 1, "request": self.request["requestID"], "sha": "b" * 40,
                     "run": self.ctx["runID"], "attempt": "1", "config": self.config}
        ciphertext = handoff.openssl(["pkeyutl", "-encrypt", "-pubin", "-inkey",
            str(Path(self.temporary.name) / "public.pem"), "-pkeyopt", "rsa_padding_mode:oaep",
            "-pkeyopt", "rsa_oaep_md:sha256", "-pkeyopt", "rsa_mgf1_md:sha256"], json.dumps(malicious).encode())
        with self.assertRaises(handoff.HandoffError):
            handoff.decrypt(self.directory, dict(self.packet, ciphertext=base64.b64encode(ciphertext).decode()),
                            self.ctx, now=self.now)

    def test_expiry_and_invalid_public_key_rejected(self):
        for request, now in [(self.request, self.now + handoff.TIMEOUT_SECONDS),
                             (dict(self.request, publicKey="invalid"), self.now)]:
            with self.assertRaises(handoff.HandoffError):
                handoff.validate_request(request, self.ctx, now)

    def test_poll_deadline_is_bounded(self):
        clock = [1000]
        calls = []
        def fetch(ctx, token, timeout):
            calls.append(ctx)
            return None
        def sleep(seconds):
            clock[0] += seconds
        with self.assertRaisesRegex(handoff.HandoffError, "timed out"):
            handoff.wait_for_packet(self.ctx, "synthetic", 1005, fetch=fetch,
                                    clock=lambda: clock[0], sleep=sleep)
        self.assertEqual(clock[0], 1005)
        self.assertEqual(len(calls), 3)

    def test_invalid_config_cannot_inject_environment_variables(self):
        for config in ({"PATH": "something"}, {"TMDB_API_KEY": "bad"}, {"TMDB_API_KEY": None}):
            with self.assertRaises(handoff.HandoffError):
                handoff.validate_config(config)

    def test_cleanup_removes_runner_private_material(self):
        path = Path(self.temporary.name) / "cleanup"
        path.mkdir()
        (path / "private.pem").write_text("synthetic")
        handoff.cleanup(path)
        self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
