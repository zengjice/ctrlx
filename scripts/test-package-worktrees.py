#!/usr/bin/env python3
"""Worktree guard regressions; never builds, signs or installs an app."""
from pathlib import Path
import shutil
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

    def test_save_space_cleanup_stays_in_selected_git_worktree(self):
        caches = []
        apps = []
        artifacts = []
        for root in (self.primary.resolve(), self.linked.resolve()):
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(SCRIPTS / "clean-build.py", scripts / "clean-build.py")
            cache = root / ".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o"
            cache.parent.mkdir(parents=True)
            cache.write_text("fixture")
            caches.append(cache)
            app = root / ".build-local/DerivedData/iOS/Build/Products/CtrlX.app/executable"
            app.parent.mkdir(parents=True)
            app.write_text("fixture")
            apps.append(app)
            artifact = root / "dist/CtrlX-3.0.1.ipa"
            artifact.parent.mkdir()
            for suffix in ("", ".sha256", ".manifest.json"):
                Path(str(artifact) + suffix).write_text("fixture")
            artifacts.append(artifact)
        for index, root in enumerate((self.linked.resolve(), self.primary.resolve())):
            result = subprocess.run([
                "bash", "-c", 'PROJECT_ROOT="$1"; SCRIPT_DIR="$1/scripts"; source "$2"; '
                'assert_git_worktree; check_build_space "$PROJECT_ROOT"; '
                'prune_local_artifacts "$3" iOS true',
                "cleanup-test", str(root), str(SCRIPTS / "common.sh"), str(artifacts[1 - index]),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Available build space", result.stdout)
            self.assertFalse(caches[1 - index].exists())
            if index == 0:
                self.assertTrue(caches[0].exists())
            self.assertTrue(all(path.exists() for path in apps + artifacts))


if __name__ == "__main__":
    unittest.main()
