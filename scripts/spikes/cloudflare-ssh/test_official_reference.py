"""Local-only regression checks; these never read real tokens or launch SSH."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import official_reference as reference


class OfficialReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="moshpit-reference-test-")
        self.root = Path(self.temporary.name).resolve()
        self.home = mock.patch.object(reference.Path, "home", return_value=self.root)
        self.home.start()

    def tearDown(self):
        self.home.stop()
        self.temporary.cleanup()

    def cache(self):
        return reference.ExclusiveTokenCache("test.example.com", "test-aud", "test.token.signature")

    def test_cache_is_private_exclusive_and_removed(self):
        with self.cache() as cache:
            self.assertEqual(cache.path.read_bytes(), b"test.token.signature")
            self.assertEqual(cache.path.stat().st_mode & 0o777, 0o600)
            self.assertTrue(cache.guard.is_dir())
            with self.assertRaises(reference.ReferenceError):
                with self.cache():
                    self.fail("An existing token must never be overwritten")
        self.assertFalse(cache.path.exists())
        self.assertFalse(cache.guard.exists())

    def test_existing_cache_and_other_files_stay_unchanged(self):
        cache = self.cache()
        cache.directory.mkdir()
        existing = cache.directory / "existing-org-token"
        existing.write_bytes(b"existing")
        original = existing.stat()
        with cache:
            pass
        self.assertEqual(existing.read_bytes(), b"existing")
        self.assertEqual(existing.stat().st_ino, original.st_ino)
        self.assertEqual(existing.stat().st_mtime_ns, original.st_mtime_ns)

    def test_existing_guard_is_preserved(self):
        cache = self.cache()
        cache.directory.mkdir()
        cache.guard.write_bytes(b"existing lock")
        with self.assertRaises(FileExistsError):
            with cache:
                self.fail("An existing lock must never be overwritten")
        self.assertEqual(cache.guard.read_bytes(), b"existing lock")
        self.assertFalse(cache.path.exists())

    def test_cache_symlink_is_refused(self):
        other = self.root / "other"
        other.mkdir()
        (self.root / ".cloudflared").symlink_to(other, target_is_directory=True)
        with self.assertRaises(reference.ReferenceError):
            with self.cache():
                self.fail("Cache symlinks must be refused")
        self.assertEqual(list(other.iterdir()), [])

    def test_changed_inode_is_not_removed_and_guard_is_cleaned(self):
        cache = self.cache()
        with self.assertRaises(reference.ReferenceError):
            with cache:
                replacement = cache.directory / "replacement"
                replacement.write_bytes(b"replacement")
                os.replace(replacement, cache.path)
        self.assertEqual(cache.path.read_bytes(), b"replacement")
        self.assertFalse(cache.guard.exists())

    def test_interrupted_private_write_removes_own_partial_file(self):
        path = self.root / "partial"
        with mock.patch.object(reference.os, "write", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                reference.write_new(path, b"private")
        self.assertFalse(path.exists())

    def test_interrupted_cache_setup_removes_guard(self):
        cache = self.cache()
        with mock.patch.object(reference, "write_new", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                with cache:
                    self.fail("Write must be interrupted")
        self.assertFalse(cache.guard.exists())

    def test_scope_mismatch_is_refused(self):
        credentials = dict(application=dict(hostname="test.example.com", audience="aud", teamDomain="team.cloudflareaccess.com"),
                           applicationToken="test.token.signature")
        fixture = dict(endpoint="wss://test.example.com", audience="aud", team_domain="team.cloudflareaccess.com", host="127.0.0.1")
        reference.validate_scope(credentials, fixture)
        for key, value in [("endpoint", "wss://other.example.com"), ("audience", "other-aud"),
                           ("team_domain", "other.cloudflareaccess.com"), ("host", "remote.example.com")]:
            with self.subTest(field=key), self.assertRaises(reference.ReferenceError):
                reference.validate_scope(credentials, dict(fixture, **{key: value}))

    def test_failed_completed_process_does_not_signal_expired_group(self):
        process = mock.Mock(returncode=255)
        process.communicate.return_value = (b"", b"")
        process.poll.return_value = 255
        with mock.patch.object(reference.subprocess, "Popen", return_value=process), \
             mock.patch.object(reference.os, "killpg") as kill, \
             mock.patch.object(reference, "event"):
            with self.assertRaises(reference.ReferenceError):
                reference.bounded_process(["unused"])
            kill.assert_not_called()

    def test_diagnostics_only_emit_fixed_categories(self):
        labels = reference.diagnostic_categories(b"Connection timed out during banner exchange; SECRET URL header token")
        self.assertEqual(labels, ["ssh_banner_timeout"])
        self.assertNotIn("SECRET", str(labels))

    @unittest.skipUnless(Path("/usr/bin/sandbox-exec").is_file(), "macOS-only subprocess filesystem policy")
    def test_sandbox_allows_only_own_token_and_preserves_other_cache(self):
        with self.cache() as cache:
            existing = cache.directory / "existing-jwks"
            existing.write_bytes(b"public keys")
            profile = reference.sandbox_profile(cache.directory, cache.path)
            for label, arguments, allowed in [
                ("probe-directory", ["/bin/ls", str(cache.directory)], True),
                ("read-token", ["/bin/cat", str(cache.path)], True),
                ("write-token", ["/usr/bin/touch", str(cache.path)], True),
                ("read-other", ["/bin/cat", str(existing)], False),
                ("write-other", ["/usr/bin/touch", str(existing)], False),
                ("create-other", ["/usr/bin/touch", str(cache.directory / "new-jwks")], False),
                ("remove-other", ["/bin/rm", str(existing)], False),
                ("rename-other", ["/bin/mv", str(existing), str(cache.directory / "moved")], False),
            ]:
                with self.subTest(operation=label):
                    result = subprocess.run(["/usr/bin/sandbox-exec", "-p", profile] + arguments,
                                            capture_output=True, timeout=5)
                    self.assertEqual(result.returncode == 0, allowed)
            self.assertEqual(existing.read_bytes(), b"public keys")
            self.assertFalse((cache.directory / "new-jwks").exists())


if __name__ == "__main__":
    unittest.main()
