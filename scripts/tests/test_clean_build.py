#!/usr/bin/env python3
"""Cleanup regressions using disposable fixtures, never real build caches."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("clean_build", SCRIPTS / "clean-build.py")
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


class BuildCleanupTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ctrlx-clean-build-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name) / "worktree with spaces"
        self.root.mkdir()
        self.other = Path(directory.name) / "other-worktree"
        self.other.mkdir()

    def file(self, relative, root=None):
        path = (root or self.root) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n")
        return path

    def artifact(self, version, extension="ipa", timestamp=1):
        path = self.file(f"dist/CtrlX-{version}.{extension}")
        self.file(str(path.relative_to(self.root)) + ".sha256")
        self.file(str(path.relative_to(self.root)) + ".manifest.json")
        os.utime(path, (timestamp, timestamp))
        return path

    def clean(self, targets, apply=True):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            storage.clean(self.root, targets, apply)
        return output.getvalue()

    def test_keeps_current_and_newest_other_package_with_metadata(self):
        for extension in ("ipa", "dmg"):
            with self.subTest(extension=extension):
                oldest = self.artifact("3.0.1", extension, 1)
                recent = self.artifact("3.0.2", extension, 2)
                current = self.artifact("3.0.3", extension, 3)
                previous = self.file(str(oldest.relative_to(self.root)) + ".previous")
                self.clean(storage.artifact_targets(self.root, current))
                for kept in (recent, current):
                    self.assertTrue(kept.exists())
                    self.assertTrue(Path(str(kept) + ".sha256").exists())
                    self.assertTrue(Path(str(kept) + ".manifest.json").exists())
                for removed in (oldest, Path(str(oldest) + ".sha256"),
                                Path(str(oldest) + ".manifest.json"), previous):
                    self.assertFalse(removed.exists())

    def test_protects_current_even_when_its_timestamp_is_oldest(self):
        current = self.artifact("3.0.1", timestamp=1)
        middle = self.artifact("3.0.2", timestamp=2)
        newest = self.artifact("3.0.3", timestamp=3)
        self.clean(storage.artifact_targets(self.root, current))
        self.assertTrue(current.exists())
        self.assertTrue(newest.exists())
        self.assertFalse(middle.exists())

    def test_platforms_are_pruned_independently(self):
        packages = [self.artifact(f"3.0.{i}", "dmg", i) for i in range(3)]
        self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.artifact("3.0.3")
        self.clean(storage.artifact_targets(self.root, current))
        self.assertTrue(all(path.exists() for path in packages))

    def test_two_packages_require_no_cleanup(self):
        self.artifact("3.0.1")
        current = self.artifact("3.0.2")
        self.assertEqual(storage.artifact_targets(self.root, current), [])

    def test_preview_never_deletes(self):
        old = self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.artifact("3.0.3")
        output = self.clean(storage.artifact_targets(self.root, current), apply=False)
        self.assertIn("Preview only", output)
        self.assertTrue(old.exists())

    def test_unknown_files_and_subdirectories_are_preserved(self):
        sentinels = [self.file(name) for name in (
            "dist/manual-backup.ipa", "dist/plugin.zip", "dist/qcloud-release/3.0.1/report.json",
            "dist/CtrlX-3.0.1.ipa-extra", "dist/custom/CtrlX-3.0.1.ipa",
        )]
        self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.artifact("3.0.3")
        self.clean(storage.artifact_targets(self.root, current))
        self.assertTrue(all(path.exists() for path in sentinels))

    def test_missing_current_metadata_prevents_pruning(self):
        old = self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.file("dist/CtrlX-3.0.3.ipa")
        with self.assertRaises(ValueError):
            storage.artifact_targets(self.root, current)
        self.assertTrue(old.exists())

    def test_only_worktree_dist_artifacts_are_accepted(self):
        for current in (self.file("CtrlX-3.0.1.ipa"), self.file("dist/backup.ipa"),
                        self.file("dist/CtrlX-3.0.1.ipa", self.other)):
            with self.subTest(current=current), self.assertRaises(ValueError):
                storage.artifact_targets(self.root, current)

    def test_deep_cleanup_only_removes_allowlisted_caches(self):
        removed = [self.file(f"{name}/cached.bin") for name in storage.DEEP_CACHE_DIRS]
        kept = [self.file(name) for name in (
            "Config/Local.xcconfig", "Config/Local-macOS.xcconfig", "source.swift",
            "dist/CtrlX-3.0.1.ipa", ".build-local/custom/notes.txt",
        )]
        outside = self.file(".build-local/DerivedData/cached.bin", self.other)
        profile = self.file("browser-profile/Cookies", self.other)
        self.clean(storage.deep_targets(self.root))
        self.assertTrue(all(not path.exists() for path in removed))
        self.assertTrue(all(path.exists() for path in kept + [outside, profile]))

    def test_symlinked_cache_parent_is_rejected_before_any_deletion(self):
        outside = self.file("cache/sentinel", self.other)
        (self.root / ".build-local").symlink_to(self.other / "cache", target_is_directory=True)
        with self.assertRaises(ValueError):
            storage.deep_targets(self.root)
        self.assertTrue(outside.exists())

    def test_symlinked_artifact_metadata_is_rejected(self):
        old = self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.artifact("3.0.3")
        metadata = Path(str(old) + ".sha256")
        metadata.unlink()
        outside = self.file("sentinel", self.other)
        metadata.symlink_to(outside)
        with self.assertRaises(ValueError):
            storage.artifact_targets(self.root, current)
        self.assertTrue(old.exists())
        self.assertTrue(outside.exists())

    def test_artifact_metadata_directory_is_rejected_before_pruning(self):
        old = self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.artifact("3.0.3")
        metadata = Path(str(old) + ".sha256")
        metadata.unlink()
        metadata.mkdir()
        with self.assertRaises(ValueError):
            storage.artifact_targets(self.root, current)
        self.assertTrue(old.exists())

    def test_symlinked_dist_is_rejected(self):
        outside = self.other / "dist"
        outside.mkdir()
        (self.root / "dist").symlink_to(outside, target_is_directory=True)
        current = self.artifact("3.0.3")
        with self.assertRaises(ValueError):
            storage.artifact_targets(self.root, current)
        self.assertTrue(current.exists())

    def test_symlinks_inside_cache_are_not_followed(self):
        outside = self.file("cache/sentinel", self.other)
        cache = self.root / ".build-local/DerivedData"
        cache.mkdir(parents=True)
        (cache / "external").symlink_to(outside.parent, target_is_directory=True)
        self.clean(storage.deep_targets(self.root))
        self.assertFalse(cache.exists())
        self.assertTrue(outside.exists())

    def test_invalid_later_target_prevents_partial_deletion(self):
        valid = self.file(".build-local/DerivedData/cached.bin")
        outside = self.file("sentinel", self.other)
        with self.assertRaises(ValueError):
            self.clean([valid, outside])
        self.assertTrue(valid.exists())
        self.assertTrue(outside.exists())

    def test_root_and_parent_traversal_are_rejected(self):
        for path in (self.root, self.root / ".." / "other-worktree"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                storage.validate_path(self.root, path)

    def test_cli_is_preview_by_default(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        script = scripts / "clean-build.py"
        shutil.copy2(SCRIPTS / "clean-build.py", script)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        cache = self.file(".build-local/DerivedData/cached.bin")
        result = subprocess.run(["python3", str(script), "deep"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preview only", result.stdout)
        self.assertTrue(cache.exists())

    def test_packaging_prunes_only_after_metadata_is_written(self):
        for name, variable in (("package-local-ios.sh", "IPA_PATH"),
                               ("package-local-macos.sh", "DMG_PATH"), ("release.sh", "DMG_PATH")):
            with self.subTest(script=name):
                script = (SCRIPTS / name).read_text()
                self.assertIn(f'write_artifact_metadata "${variable}"\nprune_local_artifacts "${variable}"', script)

    def test_packaging_traps_clean_temporary_copies_on_success_and_failure(self):
        for platform in ("ios", "macos"):
            script = (SCRIPTS / f"package-local-{platform}.sh").read_text()
            start = script.index('PACKAGE_ROOT="$(/usr/bin/mktemp')
            end = script.index(" EXIT\n", start) + len(" EXIT\n")
            setup = script[start:end]
            for status in (0, 7):
                with self.subTest(platform=platform, status=status):
                    build = self.root / f"build-{platform}-{status}"
                    build.mkdir()
                    app = self.file(f"build-{platform}-{status}/DerivedData/CtrlX.app/executable")
                    commands = 'LOCAL_BUILD_ROOT="$1"\n' + setup + '\nprintf "%s\\n" "$PACKAGE_ROOT"\n'
                    if platform == "ios":
                        commands += 'PROFILE_ROOT="$(/usr/bin/mktemp -d "$LOCAL_BUILD_ROOT/profiles.XXXXXX")"\nprintf "%s\\n" "$PROFILE_ROOT"\n'
                    commands += 'exit "$2"\n'
                    result = subprocess.run(["bash", "-c", commands, "cleanup-test", str(build), str(status)],
                                            text=True, capture_output=True)
                    self.assertEqual(result.returncode, status, result.stderr)
                    paths = result.stdout.splitlines()
                    self.assertEqual(len(paths), 2 if platform == "ios" else 1)
                    self.assertTrue(all(not Path(path).exists() for path in paths))
                    self.assertTrue(app.exists())


if __name__ == "__main__":
    unittest.main()
