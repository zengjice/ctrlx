#!/usr/bin/env python3
"""Worktree guard regressions; never builds, signs or installs an app."""
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent


class PackageWorktreeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ctrlx-package-worktree-")
        self.addCleanup(self.directory.cleanup)
        self.primary = Path(self.directory.name) / "primary"
        self.primary.mkdir()
        self.git("init", "-q")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "-q", "--allow-empty", "-m", "fixture")
        self.linked = Path(self.directory.name) / "linked"
        self.git("worktree", "add", "-q", "-b", "test-release", str(self.linked))

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.primary), *arguments], check=True,
                       capture_output=True, text=True)

    def guard(self, root):
        return subprocess.run([
            "bash", "-c", 'PROJECT_ROOT="$1"; source "$2"; assert_git_worktree',
            "guard-test", str(root), str(SCRIPTS / "common.sh"),
        ], capture_output=True, text=True)

    def test_primary_is_supported(self):
        self.assertEqual(self.guard(self.primary).returncode, 0)

    def test_linked_is_supported_while_primary_is_dirty(self):
        (self.primary / "other-agent.txt").write_text("work in progress\n")
        self.assertEqual(self.guard(self.linked).returncode, 0)
        self.assertEqual((self.primary / "other-agent.txt").read_text(), "work in progress\n")

    def test_local_development_packaging_still_accepts_uncommitted_work(self):
        (self.linked / "draft.txt").write_text("local build\n")
        self.assertEqual(self.guard(self.linked).returncode, 0)

    def test_non_repository_is_rejected(self):
        self.assertNotEqual(self.guard(Path(self.directory.name)).returncode, 0)

    def test_subdirectory_is_not_a_worktree_root(self):
        nested = self.linked / "nested"
        nested.mkdir()
        self.assertNotEqual(self.guard(nested).returncode, 0)

    def test_all_packaging_entrypoints_use_the_worktree_guard(self):
        for name in ("package-local-macos.sh", "package-local-ios.sh", "release.sh"):
            with self.subTest(script=name):
                script = (SCRIPTS / name).read_text()
                self.assertIn("\nassert_git_worktree\n", script)
                self.assertNotIn("assert_primary_worktree", script)
                self.assertIn('PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"', script)


if __name__ == "__main__":
    unittest.main()
