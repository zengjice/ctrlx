"""Worktree locking and package transactions; never build or install a real App."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import local_build as build


class LocalBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ctrlx-build-policy-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("local_build.py", "clean-build.py", "common.sh", "package-local-macos.sh", "package-local-ios.sh",
                     "build-agent-browser.sh", "prepare-agent-browser-engine.sh", "build-device-installer.sh"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.helper = scripts / "local_build.py"
        self.cleaner = scripts / "clean-build.py"

    def invoke(self, *args):
        return subprocess.run([str(arg) for arg in args], capture_output=True, text=True, timeout=10)

    def test_lock_blocks_both_packagers_and_destructive_cleanup_but_not_preview(self):
        cache = self.root / ".build-local/DerivedData/iOS/Build/Intermediates.noindex"
        cache.mkdir(parents=True)
        with build.worktree_lock(self.root):
            for mode in ("idle", "deep", "retained", "tests"):
                result = self.invoke(sys.executable, self.cleaner, mode, "--yes")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Another build", result.stderr)
                self.assertTrue(cache.exists())
            for platform in ("ios", "macos"):
                result = self.invoke("bash", self.root / f"scripts/package-local-{platform}.sh", "--app-only")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Another build", result.stderr)
            for name in ("build-agent-browser.sh", "prepare-agent-browser-engine.sh", "build-device-installer.sh"):
                result = self.invoke("bash", self.root / "scripts" / name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Another build", result.stderr)
            preview = self.invoke(sys.executable, self.cleaner, "idle")
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertIn("Preview only", preview.stdout)
        self.assertEqual(self.invoke(sys.executable, self.cleaner, "idle", "--yes").returncode, 0)
        self.assertFalse(cache.exists())

    def test_nested_shell_borrows_lock_without_unlocking_parent(self):
        with build.worktree_lock(self.root) as descriptor:
            result = build.run_child(["bash", "-c", 'python3 "$1" lock-held && python3 "$2" retained --yes',
                                      "test", self.helper, self.cleaner], descriptor, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            blocked = self.invoke(sys.executable, self.helper, "run", "--", "true")
            self.assertNotEqual(blocked.returncode, 0)
        self.assertEqual(self.invoke(sys.executable, self.helper, "run", "--", "true").returncode, 0)

    def test_shell_wrapper_reexec_preserves_arguments_and_deferred_cleanup(self):
        wrapper = self.root / "scripts/fixture.sh"
        wrapper.write_text('''set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
with_worktree_lock "$@"
printf '%s\\n' "$@"
prune_local_artifacts "" iOS true
''')
        cache = self.root / ".build-local/DerivedData/iOS/Build/Intermediates.noindex"
        cache.mkdir(parents=True)
        with build.worktree_lock(self.root) as descriptor:
            result = build.run_child(["bash", wrapper, "argument with spaces"], descriptor,
                                     defer_cleanup=True, capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), "argument with spaces")
            self.assertTrue(cache.exists())
        result = self.invoke("bash", wrapper, "argument with spaces")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("argument with spaces", result.stdout)
        self.assertFalse(cache.exists())

    def test_managed_artifact_passes_borrowed_lock_to_nested_command(self):
        artifact = self.root / ".build-local/upstream-browser-proof.fixture"
        artifact.mkdir(parents=True)
        with build.worktree_lock(self.root) as descriptor:
            result = build.run_child([sys.executable, self.cleaner, "use-artifact", "--path", artifact,
                                      "--", sys.executable, self.helper, "lock-held"], descriptor,
                                     capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((artifact / ".ctrlx-retained.json").read_text())["status"], "completed")

    def test_other_worktree_can_build_and_failed_child_releases_lock(self):
        other = self.root / "other"
        other.mkdir()
        with build.worktree_lock(other):
            result = self.invoke(sys.executable, self.helper, "run", "--", "bash", "-c", "exit 7")
            self.assertEqual(result.returncode, 7)
            with build.worktree_lock(self.root):
                pass

    def test_foreign_inherited_descriptor_is_rejected(self):
        (self.root / ".build-local").mkdir()
        (self.root / ".build-local/operation.lock").touch()
        foreign = self.root / "foreign.lock"
        with foreign.open("w") as opened, mock.patch.dict(os.environ, {build.LOCK_ENV: str(opened.fileno())}):
            with self.assertRaisesRegex(ValueError, "another worktree"):
                with build.worktree_lock(self.root):
                    self.fail("foreign lock accepted")

    def test_app_only_exits_before_creating_packages_and_cleans_only_on_success(self):
        for platform in ("ios", "macos"):
            source = (SCRIPTS / f"package-local-{platform}.sh").read_text()
            self.assertLess(source.index("invalidate_local_app"), source.index("/usr/bin/xcodebuild"))
            start = source.index("\nrecord_local_app")
            end = source.index('PACKAGE_ROOT="$(/usr/bin/mktemp', start)
            branch = source[start:end]
            for status in (0, 7):
                commands = '''set -eu
APP_ONLY=true
SAVE_SPACE=true
CONFIGURATION=Debug
APP_PATH=/fixture/CtrlX.app
record_local_app() { return "$1"; }
'''.replace('return "$1"', f"return {status}") + '''
prune_local_artifacts() { printf 'prune:%s:%s:%s\\n' "$@"; }
log_success() { :; }
''' + branch + '\necho unexpected-packaging\n'
                result = self.invoke("bash", "-c", commands)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertNotIn("unexpected-packaging", result.stdout)
                expected = f"prune::{('iOS' if platform == 'ios' else 'macOS')}:true\n" if status == 0 else ""
                self.assertEqual(result.stdout, expected)

    def package(self, suffix=".dmg", existing=True):
        target = self.root / f"dist/CtrlX-3.0.58{suffix}"
        stage = self.root / ".build-local/stage" / target.name
        stage.parent.mkdir(parents=True)
        target.parent.mkdir()
        if suffix == ".ipa":
            with zipfile.ZipFile(stage, "w") as archive:
                archive.writestr("Payload/CtrlX.app/test", "new package")
        else:
            stage.write_bytes(b"new package")
        digest = hashlib.sha256(stage.read_bytes()).hexdigest()
        Path(str(stage) + ".sha256").write_text(digest + "  " + target.name)
        Path(str(stage) + ".manifest.json").write_text(json.dumps({"artifact": target.name, "sha256": digest}))
        if existing:
            for extra in ("", ".sha256", ".manifest.json"):
                Path(str(target) + extra).write_bytes(b"old" + extra.encode())
        return stage, target

    def assert_old(self, target):
        for extra in ("", ".sha256", ".manifest.json"):
            self.assertEqual(Path(str(target) + extra).read_bytes(), b"old" + extra.encode())

    def test_package_replacement_publishes_all_three_files(self):
        stage, target = self.package(suffix=".ipa")
        expected = {extra: Path(str(stage) + extra).read_bytes() for extra in ("", ".sha256", ".manifest.json")}
        build.publish_package(self.root, stage, target)
        for extra, content in expected.items():
            self.assertEqual(Path(str(target) + extra).read_bytes(), content)
        self.assertFalse(list(target.parent.glob(".package-replace.*")))

    def test_bad_integrity_preserves_old_package(self):
        stage, target = self.package()
        stage.write_bytes(b"partial")
        with self.assertRaisesRegex(ValueError, "integrity"):
            build.publish_package(self.root, stage, target)
        self.assert_old(target)

    def test_invalid_ipa_preserves_old_package_even_with_matching_checksum(self):
        stage, target = self.package(suffix=".ipa")
        stage.write_bytes(b"not a zip")
        digest = hashlib.sha256(stage.read_bytes()).hexdigest()
        Path(str(stage) + ".sha256").write_text(digest)
        Path(str(stage) + ".manifest.json").write_text(json.dumps({"artifact": target.name, "sha256": digest}))
        with self.assertRaises(zipfile.BadZipFile):
            build.publish_package(self.root, stage, target)
        self.assert_old(target)

    def test_failure_mid_publication_restores_old_package_and_sidecars(self):
        stage, target = self.package()
        replace = os.replace
        for failure_at in (1, 2):
            # Recreate files moved by the preceding failed attempt.
            for extra in ("", ".sha256", ".manifest.json"):
                if not Path(str(stage) + extra).exists():
                    Path(str(stage) + extra).write_bytes(b"new package")
            digest = hashlib.sha256(stage.read_bytes()).hexdigest()
            Path(str(stage) + ".sha256").write_text(digest)
            Path(str(stage) + ".manifest.json").write_text(json.dumps({"artifact": target.name, "sha256": digest}))
            calls = 0

            def fail_once(source, destination):
                nonlocal calls
                calls += 1
                if calls == failure_at + 1:
                    raise OSError("replace failed")
                return replace(source, destination)

            with mock.patch.object(build.os, "replace", side_effect=fail_once):
                with self.assertRaisesRegex(OSError, "replace failed"):
                    build.publish_package(self.root, stage, target)
            self.assert_old(target)
            self.assertFalse(list(target.parent.glob(".package-replace.*")))

    def test_failed_first_package_leaves_no_partial_published_files(self):
        stage, target = self.package(existing=False)
        replace = os.replace

        def fail_sidecar(source, destination):
            if str(source).endswith(".sha256"):
                raise OSError("failure")
            return replace(source, destination)

        with mock.patch.object(build.os, "replace", side_effect=fail_sidecar):
            with self.assertRaises(OSError):
                build.publish_package(self.root, stage, target)
        self.assertEqual(list(target.parent.iterdir()), [])

    def test_rollback_failure_retains_original_files_for_recovery(self):
        stage, target = self.package()
        replace = os.replace

        def fail_after_package(source, destination):
            if source == stage:
                return replace(source, destination)
            raise OSError("failure")

        with mock.patch.object(build.os, "replace", side_effect=fail_after_package):
            with self.assertRaisesRegex(RuntimeError, "old files retained"):
                build.publish_package(self.root, stage, target)
        backup, = target.parent.glob(".package-replace.*")
        self.assert_old(backup / target.name)

    def test_symlinked_package_is_rejected_without_modifying_target(self):
        stage, target = self.package()
        stage.unlink()
        stage.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            build.publish_package(self.root, stage, target)
        self.assert_old(target)


if __name__ == "__main__":
    unittest.main()
