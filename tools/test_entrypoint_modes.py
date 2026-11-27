"""Portable regression tests for committed and checked-out entrypoints."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from check_entrypoint_modes import ENTRYPOINTS, check


class EntrypointModeTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Mode fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        for name in ENTRYPOINTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
            self.git("add", "--", name)
            self.git("update-index", "--chmod=+x", "--", name)
        self.git("commit", "-qm", "fixture")
        self.path = self.root / ENTRYPOINTS[0]

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.root), *args], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def test_all_entrypoints_valid(self):
        self.assertEqual(check(self.root), [])

    def test_wrong_committed_mode_even_if_checkout_is_executable(self):
        self.git("update-index", "--chmod=-x", "--", ENTRYPOINTS[0])
        self.git("commit", "-qm", "wrong tracked mode")
        self.path.chmod(0o755)
        self.assertEqual(check(self.root), [
            f"{ENTRYPOINTS[0]}: expected Git mode 100755, got 100644"])

    def test_missing_checkout_execute_bit(self):
        self.path.chmod(0o644)
        self.assertEqual(check(self.root), [
            f"{ENTRYPOINTS[0]}: checkout is not executable"])

    def test_missing_checkout_file(self):
        self.path.unlink()
        self.assertEqual(check(self.root), [
            f"{ENTRYPOINTS[0]}: missing or not a regular file"])

    def test_checkout_symlink_rejected(self):
        self.path.unlink()
        self.path.symlink_to(self.root / ENTRYPOINTS[1])
        self.assertEqual(check(self.root), [
            f"{ENTRYPOINTS[0]}: missing or not a regular file"])

    def test_missing_tracked_file(self):
        self.git("rm", "--cached", "--", ENTRYPOINTS[0])
        self.git("commit", "-qm", "untracked entrypoint")
        self.assertEqual(check(self.root), [
            f"{ENTRYPOINTS[0]}: expected Git mode 100755, got None"])

    def test_staged_mode_change_is_not_committed_provenance(self):
        self.git("update-index", "--chmod=-x", "--", ENTRYPOINTS[0])
        self.assertEqual(check(self.root), [])


if __name__ == "__main__":
    unittest.main()
