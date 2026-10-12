#!/usr/bin/env python3
"""Cleanup regressions using disposable fixtures, never real build caches."""
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import select
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("clean_build", SCRIPTS / "clean-build.py")
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


class BuildCleanupTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ctrlx-clean-build-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve() / "worktree with spaces"
        self.root.mkdir()
        self.other = Path(directory.name).resolve() / "other-worktree"
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

    def publication(self, version="3.0.3", status="published"):
        stage = f"dist/qcloud-release/{version}"
        self.file(f"{stage}/publish.lock")
        public = self.file(f"{stage}/public-CtrlX-{version}.dmg")
        report = self.file(f"{stage}/publish-report.json")
        report.write_text(json.dumps({
            "version": version, "artifact": f"CtrlX-{version}.dmg", "status": status,
            "sha256": hashlib.sha256(public.read_bytes()).hexdigest(),
        }))
        return public, report

    def clean_receipts(self, apply=True):
        with contextlib.ExitStack() as locks:
            return self.clean(storage.receipt_targets(self.root, locks), apply)

    def retained(self, name, timestamp=1, status="completed", root=None):
        root = root or self.root
        app = self.file(f".build-local/{name}/CtrlX.app/executable", root)
        directory = app.parents[1]
        marker = directory / storage.RETAINED_MARKER
        marker.write_text(json.dumps({"version": 1, "worktree": str(root),
                                     "group": storage.retained_group(root, directory), "status": status}))
        os.utime(marker, (timestamp, timestamp))
        return directory

    def clean_retained(self, apply=True):
        with contextlib.ExitStack() as locks:
            return self.clean(storage.retained_targets(self.root, locks), apply)

    def install_cleanup_cli(self):
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        script = scripts / "clean-build.py"
        shutil.copy2(SCRIPTS / script.name, script)
        shutil.copy2(SCRIPTS / "local_build.py", scripts / "local_build.py")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        return [sys.executable, str(script)]

    def test_retained_copies_keep_two_per_kind_based_on_completion_not_directory_time(self):
        proofs = [self.retained(f"upstream-browser-proof.copy{i}", i) for i in range(4)]
        backups = [self.retained(name, i) for i, name in enumerate((
            "mac-install.old", "macOS-install-backup.middle", "mac-install-backup.new"))]
        os.utime(proofs[0], (100, 100))
        self.assertIn("Preview only", self.clean_retained(apply=False))
        self.assertTrue(all(path.exists() for path in proofs + backups))
        self.clean_retained()
        self.assertTrue(all(path.exists() for path in proofs[-2:] + backups[-2:]))
        self.assertTrue(all(not path.exists() for path in proofs[:-2] + backups[:-2]))

    def test_retention_keeps_failed_unmarked_foreign_and_unrecognized_data(self):
        old = self.retained("upstream-browser-proof.old")
        failed = self.retained("upstream-browser-proof.failed", 2, status="incomplete")
        foreign = self.retained("upstream-browser-proof.foreign", 3)
        marker = foreign / storage.RETAINED_MARKER
        record = json.loads(marker.read_text())
        marker.write_text(json.dumps({**record, "worktree": str(self.other)}))
        unmanaged = self.file(".build-local/upstream-browser-proof.unmanaged/notes.txt")
        unknown = self.file(".build-local/agent-simulator-acceptance/evidence.json")
        source = self.file("source.swift")
        shared = self.file(".build-local/SourcePackages/checkouts/source.swift")
        other = self.retained("upstream-browser-proof.other", root=self.other)
        current = self.retained("upstream-browser-proof.current", 4)
        self.clean_retained()
        self.assertTrue(all(path.exists() for path in (old, failed, foreign, unmanaged, unknown,
                                                       source, shared, other, current)))

    def test_unreadable_marker_is_kept(self):
        bad = self.retained("upstream-browser-proof.bad")
        (bad / storage.RETAINED_MARKER).write_text("{interrupted write")
        with contextlib.redirect_stderr(io.StringIO()):
            self.clean_retained()
        self.assertTrue(bad.exists())

    def test_active_artifact_is_skipped_and_cleanup_holds_locks_until_deletion(self):
        active, old, recent, newest = [self.retained(f"upstream-browser-proof.copy{i}", i) for i in range(4)]
        with (active / storage.RETAINED_MARKER).open("r") as active_lock:
            fcntl.flock(active_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with contextlib.ExitStack() as locks:
                targets = storage.retained_targets(self.root, locks)
                self.assertEqual(targets, [old])
                with self.assertRaisesRegex(ValueError, "already in use"):
                    storage.use_artifact(self.root, old, ["true"])
                self.clean(targets)
        self.assertTrue(all(path.exists() for path in (active, recent, newest)))

    def test_running_unwrapped_app_is_kept_and_process_check_failure_preserves_all(self):
        paths = [self.retained(f"upstream-browser-proof.copy{i}", i) for i in range(3)]
        with mock.patch.object(storage.subprocess, "check_output", return_value=f"123 {paths[0]}/CtrlX.app/Contents/MacOS/CtrlX\n"):
            self.clean_retained()
        self.assertTrue(all(path.exists() for path in paths))
        with mock.patch.object(storage.subprocess, "check_output", side_effect=subprocess.TimeoutExpired("ps", 10)), \
                contextlib.redirect_stderr(io.StringIO()):
            self.clean_retained()
        self.assertTrue(all(path.exists() for path in paths))

    def test_artifact_wrapper_invalidates_old_success_before_command_and_preserves_failure(self):
        path = self.retained("mac-install-backup.fixture")
        marker = path / storage.RETAINED_MARKER
        def command(_):
            self.assertEqual(json.loads(marker.read_text())["status"], "incomplete")
            with contextlib.ExitStack() as locks:
                self.assertEqual(storage.retained_targets(self.root, locks), [])
            return subprocess.CompletedProcess([], 7)
        with mock.patch.object(storage.subprocess, "run", side_effect=command):
            self.assertEqual(storage.use_artifact(self.root, path, ["install-and-verify"]), 7)
        self.assertEqual(json.loads(marker.read_text())["status"], "incomplete")
        with mock.patch.object(storage.subprocess, "run", side_effect=OSError("cannot start")):
            with self.assertRaises(OSError):
                storage.use_artifact(self.root, path, ["missing-command"])
        self.assertEqual(json.loads(marker.read_text())["status"], "incomplete")

    def test_signal_exit_and_interrupt_do_not_mark_completion(self):
        path = self.retained("upstream-browser-proof.interrupted")
        with mock.patch.object(storage.subprocess, "run", return_value=subprocess.CompletedProcess([], -15)):
            self.assertEqual(storage.use_artifact(self.root, path, ["fixture"]), 143)
        with mock.patch.object(storage.subprocess, "run", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                storage.use_artifact(self.root, path, ["fixture"])
        self.assertEqual(json.loads((path / storage.RETAINED_MARKER).read_text())["status"], "incomplete")

    def test_real_runner_and_cleanup_coordinate_across_processes(self):
        cli = self.install_cleanup_cli()
        old, recent, newest = [self.retained(f"upstream-browser-proof.copy{i}", i) for i in range(3)]
        process = subprocess.Popen([*cli, "use-artifact", "--path", str(old), "--", sys.executable, "-c",
                                    "import sys; print('ready', flush=True); sys.stdin.read(1)"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], "Runner did not become ready")
            self.assertEqual(process.stdout.readline().strip(), "ready")
            result = subprocess.run([*cli, "retained", "--yes"], text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Skipping active artifact", result.stdout)
            self.assertTrue(all(path.exists() for path in (old, recent, newest)))
            output, error = process.communicate("x", timeout=10)
            self.assertEqual(process.returncode, 0, error)
            self.assertIn("Completed artifact", output)
            self.assertTrue(old.exists())
            self.assertFalse(recent.exists())
            self.assertTrue(newest.exists())
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=10)

    def test_retention_cli_preserves_child_failure_exit_code_and_rejects_unsafe_paths(self):
        cli = self.install_cleanup_cli()
        path = self.retained("mac-install-backup.fixture")
        result = subprocess.run([*cli, "use-artifact", "--path", str(path), "--", sys.executable, "-c", "exit(9)"],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(json.loads((path / storage.RETAINED_MARKER).read_text())["status"], "incomplete")
        for unsafe in (self.root, self.other, self.root / ".build-local/DerivedData", self.root / ".build-local/missing"):
            with self.subTest(path=unsafe), self.assertRaises(ValueError):
                storage.use_artifact(self.root, unsafe, ["true"])
        with self.assertRaises(ValueError):
            storage.use_artifact(self.root, path, [])

    def test_symlinked_retention_directory_and_marker_cannot_escape_worktree(self):
        outside = self.retained("upstream-browser-proof.outside", root=self.other)
        local = self.root / ".build-local/upstream-browser-proof.link"
        local.parent.mkdir()
        local.symlink_to(outside)
        with self.assertRaises(ValueError):
            self.clean_retained()
        local.unlink()
        path = self.retained("upstream-browser-proof.local")
        marker = path / storage.RETAINED_MARKER
        marker.unlink()
        marker.symlink_to(outside / storage.RETAINED_MARKER)
        with self.assertRaises(ValueError):
            storage.use_artifact(self.root, path, ["true"])
        with self.assertRaises(ValueError):
            self.clean_retained()
        self.assertTrue(outside.exists())

    def test_packaging_and_idle_cli_also_apply_retention(self):
        cli = self.install_cleanup_cli()
        for mode in ("iOS", "macOS", "idle"):
            with self.subTest(mode=mode):
                copies = [self.retained(f"upstream-browser-proof.copy{i}", i) for i in range(3)]
                cache = self.file(f".build-local/DerivedData/{mode}/Build/Intermediates.noindex/object.o")
                if mode == "idle":
                    arguments = ["idle", "--yes"]
                else:
                    artifact = self.artifact("3.0.3", "ipa" if mode == "iOS" else "dmg")
                    arguments = ["prune", "--artifact", str(artifact), "--platform", mode, "--yes"]
                result = subprocess.run([*cli, *arguments], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(copies[0].exists())
                self.assertTrue(all(path.exists() for path in copies[1:]))
                self.assertEqual(cache.exists(), mode != "idle")

    def test_retained_cli_preview_does_not_delete_or_mark_legacy_copies(self):
        cli = self.install_cleanup_cli()
        copies = [self.retained(f"upstream-browser-proof.copy{i}", i) for i in range(3)]
        legacy = self.file(".build-local/upstream-browser-proof.legacy/CtrlX.app/executable").parents[1]
        result = subprocess.run([*cli, "retained"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Keeping unmanaged artifact", result.stdout)
        self.assertIn("Would remove: " + str(copies[0]), result.stdout)
        self.assertTrue(all(path.exists() for path in copies + [legacy]))
        self.assertFalse((legacy / storage.RETAINED_MARKER).exists())

    def test_browser_preparation_prints_locking_runner_with_quoted_paths(self):
        source = (SCRIPTS.parent / "CtrlxPackage/AgentBrowser/tests/prepare_upstream_probe.sh").read_text()
        tail = source[source.index("printf 'Prepared isolated fixture:"):]
        build = self.root / ".build-local/upstream-browser-proof.fixture"
        result = subprocess.run(["bash", "-c", 'PROBE_REPO="$1"; PROBE_BUILD="$2";\n' + tail,
                                 "probe-command-test", str(self.root), str(build)], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = next(line[5:] for line in result.stdout.splitlines() if line.startswith("Run: "))
        self.assertEqual(shlex.split(command), [
            "python3", str(self.root / "scripts/clean-build.py"), "use-artifact", "--path", str(build), "--",
            "python3", "-u", str(self.root / "CtrlxPackage/AgentBrowser/tests/upstream_probe.py"),
            str(build / "CtrlX.app"), str(build / "agent-browser"), str(build / "identity"),
        ])

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

    def test_debug_and_release_packages_are_pruned_independently(self):
        release = [self.artifact(f"3.0.{i}", timestamp=i) for i in range(4)]
        old = self.artifact("3.0.1-Debug", timestamp=1)
        recent = self.artifact("3.0.2-Debug", timestamp=2)
        current = self.artifact("3.0.3-Debug", timestamp=3)
        self.clean(storage.artifact_targets(self.root, current))
        self.assertFalse(old.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(current.exists())
        self.assertTrue(all(path.exists() for path in release))
        self.clean(storage.artifact_targets(self.root, release[-1]))
        self.assertEqual(sum(path.exists() for path in release), 2)
        self.assertTrue(recent.exists())
        self.assertTrue(current.exists())

    def test_packaging_cleans_only_own_platform_index_and_duplicate_dependencies(self):
        current = self.artifact("3.0.3")
        removed = [self.file(f".build-local/DerivedData/iOS/{name}/fixture")
                   for name in ("Index.noindex", "SourcePackages")]
        kept = [self.file(name) for name in (
            ".build-local/SourcePackages/checkouts/dependency.swift",
            ".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o",
            ".build-local/DerivedData/iOS/Build/Products/Release-iphoneos/CtrlX.app/executable",
            ".build-local/DerivedData/iOS/CompilationCache.noindex/cached.bin",
            ".build-local/DerivedData/iOS/ModuleCache.noindex/module.pcm",
            ".build-local/DerivedData/macOS/Index.noindex/fixture",
            ".build-local/DerivedData/macOS/SourcePackages/checkouts/dependency.swift",
            "Config/Local.xcconfig", "browser-profile/Cookies",
        )]
        self.clean(storage.packaging_cache_targets(self.root, current))
        self.assertTrue(all(not path.exists() for path in removed))
        self.assertTrue(all(path.exists() for path in kept))

    def test_macos_packaging_cleans_macos_index_not_ios(self):
        current = self.artifact("3.0.3", "dmg")
        removed = self.file(".build-local/DerivedData/macOS/Index.noindex/fixture")
        kept = self.file(".build-local/DerivedData/iOS/Index.noindex/fixture")
        self.clean(storage.packaging_cache_targets(self.root, current))
        self.assertFalse(removed.exists())
        self.assertTrue(kept.exists())

    def test_derived_dependencies_preserved_without_shared_cache(self):
        current = self.artifact("3.0.3")
        kept = self.file(".build-local/DerivedData/iOS/SourcePackages/fixture")
        self.clean(storage.packaging_cache_targets(self.root, current))
        self.assertTrue(kept.exists())

    def test_test_cleanup_only_prunes_configurations_switched_to_swiftbuild(self):
        self.file("CtrlxPackage/.build/.buildSystem_debug").write_text("swiftbuild")
        self.file("CtrlxPackage/.build/.buildSystem_release").write_text("native")
        removed = [self.file(name) for name in (
            "CtrlxPackage/.build/arm64-apple-macosx/debug/object.o",
            "CtrlxPackage/.build/out/v5/records/index",
        )]
        kept = [self.file(name) for name in (
            "CtrlxPackage/.build/arm64-apple-macosx/release/executable",
            "CtrlxPackage/.build/x86_64-unknown-linux-gnu/debug/executable",
            "CtrlxPackage/.build/out/Products/Debug/test.xctest/executable",
            "CtrlxPackage/.build/out/Intermediates.noindex/object.o",
            "CtrlxPackage/.build/out/ModuleCache.noindex/module.pcm",
            "CtrlxPackage/.build/checkouts/dependency.swift",
            "CtrlxPackage/.build/repositories/repository/objects/pin",
            "CtrlxPackage/.build/artifacts/SDK/library",
            ".build-local/DerivedData/iOS/Build/Products/CtrlX.app/executable",
        )]
        outside = self.file("CtrlxPackage/.build/out/v5/records/index", self.other)
        self.clean(storage.test_cache_targets(self.root))
        self.assertTrue(all(not path.exists() for path in removed))
        self.assertTrue(all(path.exists() for path in kept + [outside]))

    def test_missing_backend_marker_preserves_native_outputs(self):
        kept = self.file("CtrlxPackage/.build/arm64-apple-macosx/debug/object.o")
        self.clean(storage.test_cache_targets(self.root))
        self.assertTrue(kept.exists())

    def test_test_save_space_preserves_swiftbuild_products_and_downloads(self):
        removed = [self.file(f"CtrlxPackage/.build/out/{name}/fixture")
                   for name in storage.TEST_CACHE_DIRS]
        kept = [self.file(name) for name in (
            "CtrlxPackage/.build/out/Products/Debug/test.xctest/executable",
            "CtrlxPackage/.build/checkouts/dependency.swift",
            "CtrlxPackage/.build/prebuilts/tool",
        )]
        self.clean(storage.test_cache_targets(self.root, save_space=True))
        self.assertTrue(all(not path.exists() for path in removed))
        self.assertTrue(all(path.exists() for path in kept))

    def test_idle_cleanup_preserves_apps_packages_downloads_and_other_worktrees(self):
        removed = [self.file(name) for name in (
            "CtrlxPackage/.build/arm64-apple-macosx/debug/object.o",
            "CtrlxPackage/.build/out/Intermediates.noindex/object.o",
            "CtrlxPackage/.build/out/v5/records/index",
            ".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o",
            ".build-local/DerivedData/macOS/ModuleCache.noindex/module.pcm",
            ".build-local/DerivedData/iOS-Simulator/Index.noindex/index",
            ".build-local/DerivedData/iOS/SourcePackages/checkouts/dependency.swift",
        )]
        kept = [self.file(name) for name in (
            "CtrlxPackage/.build/out/Products/Debug/CtrlxCLI",
            "CtrlxPackage/.build/checkouts/dependency.swift",
            "CtrlxPackage/.build/repositories/repository/objects/pin",
            "CtrlxPackage/.build/artifacts/SDK/library",
            ".build-local/SourcePackages/checkouts/dependency.swift",
            ".build-local/DerivedData/iOS/Build/Products/Release-iphoneos/CtrlX.app/executable",
            ".build-local/DerivedData/macOS/Build/Products/Release/CtrlX.app/executable",
            ".build-local/DerivedData/iOS/Logs/build.log",
            ".build-local/cef-browser-probe/sdk/include/cef.h",
            ".build-local/agent-browser/Embedded/browser",
            ".build-local/agent-browser-engine/0.38.1/agent-browser",
            "dist/CtrlX-3.0.3.ipa", "Config/Local.xcconfig", "browser-profile/Cookies",
        )]
        outside = self.file("CtrlxPackage/.build/out/Intermediates.noindex/object.o", self.other)
        targets = storage.idle_targets(self.root)
        self.assertIn("Preview only", self.clean(targets, apply=False))
        self.assertTrue(all(path.exists() for path in removed))
        self.clean(targets)
        self.assertTrue(all(not path.exists() for path in removed))
        self.assertTrue(all(path.exists() for path in kept + [outside]))
        self.assertEqual(storage.idle_targets(self.root), [])

    def test_idle_cleanup_keeps_only_dependency_copy_without_shared_cache(self):
        kept = self.file(".build-local/DerivedData/iOS/SourcePackages/checkouts/dependency.swift")
        self.clean(storage.idle_targets(self.root))
        self.assertTrue(kept.exists())

    def test_empty_shared_cache_does_not_make_derived_dependencies_redundant(self):
        kept = self.file(".build-local/DerivedData/iOS/SourcePackages/checkouts/dependency.swift")
        (self.root / ".build-local/SourcePackages/checkouts").mkdir(parents=True)
        self.clean(storage.idle_targets(self.root))
        self.assertTrue(kept.exists())
        current = self.artifact("3.0.3")
        self.clean(storage.packaging_cache_targets(self.root, current))
        self.assertTrue(kept.exists())

    def test_test_cache_symlink_and_backend_marker_symlink_rejected(self):
        outside = self.file("outside/fixture", self.other)
        native = self.file("CtrlxPackage/.build/arm64-apple-macosx/debug/object.o")
        marker = self.file("CtrlxPackage/.build/.buildSystem_debug")
        marker.unlink()
        marker.symlink_to(outside)
        with self.assertRaises(ValueError):
            storage.test_cache_targets(self.root)
        self.assertTrue(native.exists())
        marker.unlink()
        marker.write_text("swiftbuild")
        out = self.root / "CtrlxPackage/.build/out"
        out.symlink_to(outside.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            storage.test_cache_targets(self.root)
        self.assertTrue(native.exists())
        self.assertTrue(outside.exists())

    def test_idle_platform_symlink_rejected_before_any_deletion(self):
        existing = self.file("CtrlxPackage/.build/out/v5/records/index")
        outside = self.file("cache/Build/Intermediates.noindex/object.o", self.other)
        derived = self.root / ".build-local/DerivedData"
        derived.mkdir(parents=True)
        (derived / "iOS").symlink_to(self.other / "cache", target_is_directory=True)
        with self.assertRaises(ValueError):
            storage.idle_targets(self.root)
        self.assertTrue(existing.exists())
        self.assertTrue(outside.exists())

    def test_packaging_cache_symlink_rejected(self):
        current = self.artifact("3.0.3")
        outside = self.file("index/fixture", self.other)
        derived = self.root / ".build-local/DerivedData/iOS"
        derived.mkdir(parents=True)
        (derived / "Index.noindex").symlink_to(outside.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            storage.packaging_cache_targets(self.root, current)
        self.assertTrue(outside.exists())

    def test_save_space_only_removes_selected_platform_compilation_caches(self):
        for platform, extension, other_platform in (("iOS", "ipa", "macOS"), ("macOS", "dmg", "iOS")):
            with self.subTest(platform=platform):
                current = self.artifact("3.0.3", extension)
                removed = [self.file(f".build-local/DerivedData/{platform}/{name}/fixture")
                           for name in storage.COMPILATION_CACHE_DIRS]
                kept = [self.file(name) for name in (
                    f".build-local/DerivedData/{platform}/Build/Products/CtrlX.app/executable",
                    f".build-local/DerivedData/{platform}/Build/Products/CtrlX.app/PlugIns/extension.appex/executable",
                    f".build-local/DerivedData/{platform}/Logs/build.log",
                    f".build-local/DerivedData/{other_platform}/Build/Intermediates.noindex/object.o",
                    ".build-local/SourcePackages/checkouts/dependency.swift",
                    ".build-local/cef-browser-probe/cef.tar.bz2",
                    ".build-local/cef-browser-probe/sdk/include/cef.h",
                    ".build-local/agent-browser/Embedded/browser",
                    ".build-local/agent-browser-engine/0.38.1/agent-browser",
                    "CtrlxPackage/.build/object.o", "Config/Local.xcconfig",
                )]
                outside = self.file(f".build-local/DerivedData/{platform}/Build/Intermediates.noindex/object.o", self.other)
                self.clean(storage.packaging_cache_targets(self.root, current, save_space=True))
                self.assertTrue(all(not path.exists() for path in removed))
                self.assertTrue(all(path.exists() for path in kept + [current, outside]))

    def test_save_space_preserves_dependencies_without_shared_cache(self):
        current = self.artifact("3.0.3")
        dependency = self.file(".build-local/DerivedData/iOS/SourcePackages/checkouts/dependency.swift")
        intermediate = self.file(".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o")
        self.clean(storage.packaging_cache_targets(self.root, current, save_space=True))
        self.assertTrue(dependency.exists())
        self.assertFalse(intermediate.exists())

    def test_save_space_symlink_rejected_before_deletion(self):
        current = self.artifact("3.0.3")
        intermediate = self.file(".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o")
        outside = self.file("modules/fixture", self.other)
        (self.root / ".build-local/DerivedData/iOS/ModuleCache.noindex").symlink_to(outside.parent)
        with self.assertRaises(ValueError):
            storage.packaging_cache_targets(self.root, current, save_space=True)
        self.assertTrue(intermediate.exists())
        self.assertTrue(outside.exists())

    def test_disk_preflight_warns_below_threshold_without_deleting(self):
        cached = self.file(".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o")
        for free, warns in ((storage.LOW_SPACE_BYTES - 1, True),
                            (storage.LOW_SPACE_BYTES, False), (0, True)):
            with self.subTest(free=free), mock.patch.object(storage.shutil, "disk_usage", return_value=mock.Mock(free=free)) as usage, \
                    contextlib.redirect_stdout(io.StringIO()) as output, contextlib.redirect_stderr(io.StringIO()) as errors:
                storage.check_space(self.root)
                usage.assert_called_once_with(self.root)
                self.assertIn("GiB", output.getvalue())
                self.assertEqual("WARNING" in errors.getvalue(), warns)
                if warns:
                    self.assertIn("only cleans after success", errors.getvalue())
                self.assertTrue(cached.exists())

    def test_successful_public_copy_removed_but_all_release_evidence_preserved(self):
        public, report = self.publication()
        artifact = self.artifact("3.0.3", "dmg")
        kept = [report, artifact, *[self.file(f"dist/qcloud-release/3.0.3/{name}") for name in (
            "package.log", "install-mac.sh.before", "README.md", "public-install-mac.sh",
        )]]
        self.clean_receipts()
        self.assertFalse(public.exists())
        self.assertTrue(all(path.exists() for path in kept))

    def test_receipt_preview_and_repeated_cleanup(self):
        public, report = self.publication()
        self.assertIn("Preview only", self.clean_receipts(apply=False))
        self.assertTrue(public.exists())
        self.clean_receipts()
        self.assertIn("Nothing to clean", self.clean_receipts())
        self.assertTrue(report.exists())

    def test_failed_or_started_publications_preserved(self):
        for version, status in (("3.0.1", "failed"), ("3.0.2", "started")):
            public, _ = self.publication(version, status)
            self.clean_receipts()
            self.assertTrue(public.exists())

    def test_latest_failed_retry_preserves_download_despite_prior_success(self):
        public, report = self.publication()
        os.utime(report, (1, 1))
        self.file("dist/qcloud-release/3.0.3/publish-report-2.json").write_text(
            json.dumps({"status": "failed"}))
        self.clean_receipts()
        self.assertTrue(public.exists())

    def test_latest_successful_retry_is_cleaned(self):
        public, report = self.publication(status="already published; verified")
        newer = self.file("dist/qcloud-release/3.0.3/publish-report-2.json")
        newer.write_text(report.read_text())
        report.write_text(json.dumps({"status": "failed"}))
        os.utime(report, (1, 1))
        self.clean_receipts()
        self.assertFalse(public.exists())
        self.assertTrue(newer.exists())

    def test_mismatched_and_unreported_downloads_preserved(self):
        public, _ = self.publication()
        public.write_bytes(b"different bytes")
        unreported = self.file("dist/qcloud-release/3.0.1/public-CtrlX-3.0.1.dmg")
        unknown = self.file("dist/qcloud-release/custom/public-CtrlX-3.0.3.dmg")
        with contextlib.redirect_stderr(io.StringIO()):
            self.clean_receipts()
        self.assertTrue(all(path.exists() for path in (public, unreported, unknown)))

    def test_malformed_or_wrong_identity_report_preserves_download(self):
        public, report = self.publication()
        valid = json.loads(report.read_text())
        for contents in ("invalid json", "[]", json.dumps({**valid, "version": "3.0.2"}),
                         json.dumps({**valid, "artifact": "../../outside"}),
                         json.dumps({**valid, "sha256": None})):
            with self.subTest(contents=contents), contextlib.redirect_stderr(io.StringIO()):
                report.write_text(contents)
                self.clean_receipts()
                self.assertTrue(public.exists())

    def test_active_publication_skipped_and_lock_released_after_cleanup(self):
        public, _ = self.publication()
        with (public.parent / "publish.lock").open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.clean_receipts()
            self.assertIn("Skipping active publication", output.getvalue())
            self.assertTrue(public.exists())
        self.clean_receipts()
        self.assertFalse(public.exists())
        with (public.parent / "publish.lock").open("r") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_symlinked_receipt_or_report_rejected(self):
        public, report = self.publication()
        outside = self.file("sentinel", self.other)
        for path in (public, report):
            contents = path.read_bytes()
            path.unlink()
            path.symlink_to(outside)
            with self.assertRaises(ValueError):
                self.clean_receipts()
            self.assertTrue(outside.exists())
            path.unlink()
            path.write_bytes(contents)

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
        shutil.copy2(SCRIPTS / "local_build.py", script.parent / "local_build.py")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        cache = self.file(".build-local/DerivedData/cached.bin")
        result = subprocess.run(["python3", str(script), "deep"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preview only", result.stdout)
        self.assertTrue(cache.exists())

    def test_prune_cli_combines_cleanup_without_touching_other_worktree(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        script = scripts / "clean-build.py"
        shutil.copy2(SCRIPTS / "clean-build.py", script)
        shutil.copy2(SCRIPTS / "local_build.py", script.parent / "local_build.py")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        old = self.artifact("3.0.1", timestamp=1)
        self.artifact("3.0.2", timestamp=2)
        current = self.artifact("3.0.3", timestamp=3)
        public, report = self.publication()
        index = self.file(".build-local/DerivedData/iOS/Index.noindex/fixture")
        app = self.file(".build-local/DerivedData/iOS/Build/Products/CtrlX.app/executable")
        outside = self.file("dist/qcloud-release/3.0.3/public-CtrlX-3.0.3.dmg", self.other)
        arguments = ["python3", str(script), "prune", "--artifact", str(current), "--platform", "iOS"]
        result = subprocess.run(arguments, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(path.exists() for path in (old, public, index)))
        # The formal release uses temporary DerivedData, not the local packaging cache.
        result = subprocess.run(arguments[:-2], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(str(index.parent), result.stdout)
        result = subprocess.run([*arguments[:-1], "macOS", "--yes"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(path.exists() for path in (old, public, index)))
        result = subprocess.run([
            "bash", "-c", 'SCRIPT_DIR="$1/scripts"; source "$2"; prune_local_artifacts "$3" iOS',
            "cleanup-test", str(self.root), str(SCRIPTS / "common.sh"), str(current),
        ], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(not path.exists() for path in (old, public, index)))
        self.assertTrue(all(path.exists() for path in (current, report, app, outside)))

    def test_packaging_disables_indexing_without_disabling_incremental_compilation(self):
        for name in ("package-local-ios.sh", "package-local-macos.sh", "release.sh"):
            with self.subTest(script=name):
                source = (SCRIPTS / name).read_text()
                self.assertIn("COMPILER_INDEX_STORE_ENABLE=NO", source)
                self.assertIn("INDEX_ENABLE_DATA_STORE=NO", source)
                self.assertNotIn("COMPILATION_CACHE_ENABLE_CACHING=NO", source)
                self.assertNotIn("clean-build.py\" deep", source)

    def test_packaging_prunes_only_after_metadata_is_written(self):
        for name, variable, platform in (("package-local-ios.sh", "IPA_PATH", ' iOS "$SAVE_SPACE"'),
                                         ("package-local-macos.sh", "DMG_PATH", ' macOS "$SAVE_SPACE"'),
                                         ("release.sh", "DMG_PATH", "")):
            with self.subTest(script=name):
                script = (SCRIPTS / name).read_text()
                staged = "STAGED_IPA" if variable == "IPA_PATH" else "STAGED_DMG"
                expected = (f'write_artifact_metadata "${variable}"\n' if name == "release.sh" else
                            f'write_artifact_metadata "${staged}"\npublish_local_package "${staged}" "${variable}"\n')
                self.assertIn(expected + f'prune_local_artifacts "${variable}"{platform}\n', script)

    def test_space_saving_packaging_tail_only_cleans_after_success(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPTS / "clean-build.py", scripts / "clean-build.py")
        shutil.copy2(SCRIPTS / "local_build.py", scripts / "local_build.py")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        for platform, variable, extension in (("iOS", "IPA_PATH", "ipa"), ("macOS", "DMG_PATH", "dmg")):
            script = (SCRIPTS / f"package-local-{platform.lower()}.sh").read_text()
            staged = "STAGED_IPA" if platform == "iOS" else "STAGED_DMG"
            tail = script[script.index('write_artifact_metadata'):script.index('\nlog_success "', script.index('write_artifact_metadata'))]
            for save_space in ("false", "true"):
                for status in (0, 7):
                    with self.subTest(platform=platform, save_space=save_space, status=status):
                        current = self.artifact("3.0.3", extension)
                        intermediate = self.file(f".build-local/DerivedData/{platform}/Build/Intermediates.noindex/object.o")
                        app = self.file(f".build-local/DerivedData/{platform}/Build/Products/CtrlX.app/executable")
                        commands = 'set -euo pipefail\nSCRIPT_DIR="$1/scripts"\nsource "$2"\n' \
                            + f'{variable}="$3"\n{staged}="$3"\n' + 'SAVE_SPACE="$4"\nMETADATA_STATUS="$5"\n' \
                            + 'write_artifact_metadata() { return "$METADATA_STATUS"; }\npublish_local_package() { :; }\n' + tail
                        result = subprocess.run(["bash", "-c", commands, "packaging-test", str(self.root),
                                                 str(SCRIPTS / "common.sh"), str(current), save_space, str(status)],
                                                text=True, capture_output=True)
                        self.assertEqual(result.returncode, status, result.stderr)
                        self.assertEqual(intermediate.exists(), not (save_space == "true" and status == 0))
                        self.assertTrue(app.exists())
                        self.assertTrue(current.exists())

    def test_save_space_cli_requires_platform_and_previews_without_deleting(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        script = scripts / "clean-build.py"
        shutil.copy2(SCRIPTS / "clean-build.py", script)
        shutil.copy2(SCRIPTS / "local_build.py", script.parent / "local_build.py")
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        old = self.artifact("3.0.1")
        self.artifact("3.0.2")
        current = self.artifact("3.0.3")
        intermediate = self.file(".build-local/DerivedData/iOS/Build/Intermediates.noindex/object.o")
        arguments = ["python3", str(script), "prune", "--artifact", str(current), "--save-space"]
        result = subprocess.run([*arguments, "--yes"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires --platform", result.stderr)
        result = subprocess.run([*arguments, "--platform", "macOS", "--yes"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        result = subprocess.run([*arguments, "--platform", "iOS"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(intermediate.parent), result.stdout)
        self.assertIn("Preview only", result.stdout)
        self.assertTrue(old.exists())
        self.assertTrue(intermediate.exists())

    def test_all_packaging_checks_space_before_building(self):
        for name in ("package-local-ios.sh", "package-local-macos.sh", "release.sh"):
            with self.subTest(script=name):
                source = (SCRIPTS / name).read_text()
                preflight = source.index('check_build_space "$PROJECT_ROOT"')
                self.assertLess(preflight, source.index("xcodebuild"))
                if name == "package-local-macos.sh":
                    self.assertLess(preflight, source.index('bash "$SCRIPT_DIR/build-agent-browser.sh"'))
                if name == "release.sh":
                    self.assertIn('check_build_space "${TMPDIR:-/tmp}"', source)

    def test_macos_help_and_unknown_argument_do_not_need_signing_config(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy2(SCRIPTS / "common.sh", scripts / "common.sh")
        script = scripts / "package-local-macos.sh"
        shutil.copy2(SCRIPTS / script.name, script)
        result = subprocess.run(["bash", str(script), "--help"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--save-space", result.stdout)
        result = subprocess.run(["bash", str(script), "--unknown"], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown argument", result.stdout)
        self.assertFalse((self.root / ".build-local").exists())

    def test_packaging_traps_clean_temporary_copies_on_success_and_failure(self):
        for platform in ("ios", "macos"):
            script = (SCRIPTS / f"package-local-{platform}.sh").read_text()
            start = script.index('PACKAGE_ROOT=""')
            end = script.index(" EXIT\n", start) + len(" EXIT\n")
            setup = script[start:end]
            for status in (0, 7):
                with self.subTest(platform=platform, status=status):
                    build = self.root / f"build-{platform}-{status}"
                    build.mkdir()
                    app = self.file(f"build-{platform}-{status}/DerivedData/CtrlX.app/executable")
                    creation = next(line for line in script.splitlines() if line.startswith('PACKAGE_ROOT="$(/usr/bin/mktemp'))
                    commands = 'LOCAL_BUILD_ROOT="$1"\n' + setup + creation + '\nprintf "%s\\n" "$PACKAGE_ROOT"\n'
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
