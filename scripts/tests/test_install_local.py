#!/usr/bin/env python3
"""Offline local-install tests: disposable Apps and mocked OS commands only."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "install-local.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("install_local", SCRIPT)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)
DEVICE = "01234567-89ab-cdef-0123-456789abcdef"


class LocalInstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ctrlx-local-install-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve() / "worktree with spaces"
        self.build = self.root / ".build-local"
        self.build.mkdir(parents=True)
        self.target = self.root / "Applications/CtrlX.app"
        self.target.parent.mkdir()
        self.info = {"CFBundleExecutable": "CtrlX", "CFBundleIdentifier": "com.example.ctrlx",
                     "CFBundleShortVersionString": "3.0.58", "CFBundleVersion": "1",
                     "CtrlXBuildStamp": "new-build", "CtrlXSourceRevision": "revision",
                     "DTPlatformName": "macosx"}
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(installer, "run", side_effect=self.fake_run).start()
        mock.patch.object(installer, "quit_mac").start()
        mock.patch.object(installer, "launch_mac").start()
        self.signature_check = mock.patch.object(installer.build.subprocess, "run").start()
        self.children = mock.patch.object(installer.build, "run_child").start()
        self.output = io.StringIO()
        self.stdout = contextlib.redirect_stdout(self.output)
        self.stdout.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)

    def fake_run(self, *args, **kwargs):
        if args[0] == "/usr/bin/ditto":
            shutil.copytree(args[1], args[2])
        return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

    def app(self, path, platform="macos", stamp="new-build"):
        info = dict(self.info, CtrlXBuildStamp=stamp,
                    DTPlatformName="macosx" if platform == "macos" else "iphoneos")
        plist = path / ("Contents/Info.plist" if platform == "macos" else "Info.plist")
        plist.parent.mkdir(parents=True, exist_ok=True)
        plist.write_bytes(plistlib.dumps(info))
        if platform == "ios":
            (path / "embedded.mobileprovision").touch()
            extension = path / "PlugIns/CtrlxNotificationExtension.appex"
            extension.mkdir(parents=True)
            (extension / "embedded.mobileprovision").touch()
        return path

    def package(self, platform="macos", configuration="Release"):
        folder = "macOS" if platform == "macos" else "iOS"
        product = "Release" if platform == "macos" else f"{configuration}-iphoneos"
        app = self.app(self.build / f"DerivedData/{folder}/Build/Products/{product}/CtrlX.app", platform)
        installer.build.record_app(self.root, platform, configuration, "new-build", "revision")
        return app, installer.build.app_record_path(self.root, platform, configuration)

    def backups(self):
        return sorted(self.build.glob("mac-install-backup.*"))

    def test_signed_app_and_configuration_are_matched_without_packages(self):
        for platform, configuration in (("macos", "Release"), ("ios", "Release"), ("ios", "Debug")):
            with self.subTest(platform=platform, configuration=configuration):
                app, _ = self.package(platform, configuration)
                actual, info = installer.build.built_app(self.root, platform, configuration)
                self.assertEqual(actual, app)
                self.assertEqual(info["CtrlXBuildStamp"], "new-build")
                self.assertFalse((self.root / "dist").exists())

    def test_failed_rebuild_cannot_install_over_previous_successful_package(self):
        app, _ = self.package()
        self.app(app, stamp="partially-rebuilt")
        with self.assertRaisesRegex(ValueError, "identity mismatch"):
            installer.build.built_app(self.root, "macos", "Release")

    def test_rebuild_invalidates_previous_app_record(self):
        app, _ = self.package()
        installer.build.invalidate_app(self.root, "macos", "Release")
        with self.assertRaisesRegex(ValueError, "without --skip-build"):
            installer.build.built_app(self.root, "macos", "Release")
        self.assertTrue(app.exists())

    def test_foreign_worktree_record_is_rejected(self):
        _, record = self.package()
        data = json.loads(record.read_text())
        data["worktree"] = "/another/worktree"
        record.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "different worktree"):
            installer.build.built_app(self.root, "macos", "Release")

    def test_failed_signature_or_wrong_stamp_never_creates_completed_record(self):
        _, record = self.package()
        installer.build.invalidate_app(self.root, "macos", "Release")
        self.signature_check.side_effect = subprocess.CalledProcessError(1, "codesign")
        with self.assertRaises(subprocess.CalledProcessError):
            installer.build.record_app(self.root, "macos", "Release", "new-build", "revision")
        self.assertFalse(record.exists())
        self.signature_check.side_effect = None
        with self.assertRaisesRegex(ValueError, "stamp/revision"):
            installer.build.record_app(self.root, "macos", "Release", "wrong-stamp", "revision")
        self.assertFalse(record.exists())

    def test_unsigned_app_and_missing_extension_profile_are_rejected(self):
        app, _ = self.package("ios")
        self.signature_check.side_effect = subprocess.CalledProcessError(1, "codesign")
        with self.assertRaises(subprocess.CalledProcessError):
            installer.verify_app(app, "ios")
        self.signature_check.side_effect = None
        (app / "PlugIns/CtrlxNotificationExtension.appex/embedded.mobileprovision").unlink()
        with self.assertRaisesRegex(ValueError, "profiles"):
            installer.verify_app(app, "ios")

    def test_simulator_app_cannot_be_installed_as_device_build(self):
        app, _ = self.package("ios")
        data = installer.app_info(app, "ios")
        data["DTPlatformName"] = "iphonesimulator"
        (app / "Info.plist").write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(ValueError, "Not a CtrlX"):
            installer.verify_app(app, "ios")

    def test_mac_success_replaces_bundle_and_marks_backup(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        (self.target / "obsolete").touch()
        installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "new-build")
        self.assertFalse((self.target / "obsolete").exists())
        backup = self.backups()[0]
        self.assertTrue((backup / "CtrlX.app/obsolete").exists())
        self.assertEqual(json.loads((backup / installer.storage.RETAINED_MARKER).read_text())["status"], "completed")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])
        installer.quit_mac.assert_called_once_with(self.target)
        installer.launch_mac.assert_called_once_with(self.target)

    def test_repeated_installs_keep_only_two_completed_backups(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        for _ in range(4):
            installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(len(self.backups()), 4)  # Only the outer successful workflow prunes.
        with contextlib.ExitStack() as locks:
            installer.storage.clean(self.root, installer.storage.retained_targets(self.root, locks), True)
        self.assertEqual(len(self.backups()), 2)

    def test_quit_failure_leaves_installed_app_and_cleans_staging(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        installer.quit_mac.side_effect = RuntimeError("still running")
        with self.assertRaisesRegex(RuntimeError, "still running"):
            installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "old")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])
        installer.launch_mac.assert_not_called()

    def test_failed_post_copy_verification_restores_old_app_and_keeps_backup(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        original = installer.verify_app

        def verify(path, *args):
            if path == self.target:
                raise ValueError("verification failed")
            return original(path, *args)

        with mock.patch.object(installer, "verify_app", side_effect=verify):
            with self.assertRaisesRegex(ValueError, "verification failed"):
                installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "old")
        self.assertEqual(json.loads((self.backups()[0] / installer.storage.RETAINED_MARKER).read_text())["status"], "incomplete")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_copy_interruption_cleans_staging_without_touching_installed_app(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        installer.run.side_effect = KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "old")

    def test_backup_copy_failure_leaves_old_app_in_place(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")

        def copy(*args, **kwargs):
            if args[0] == "/usr/bin/ditto" and args[1] == self.target:
                raise OSError("disk full")
            return self.fake_run(*args, **kwargs)

        installer.run.side_effect = copy
        with self.assertRaisesRegex(OSError, "disk full"):
            installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "old")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_rename_failure_does_not_move_or_delete_existing_app(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        with mock.patch.object(Path, "rename", side_effect=PermissionError("rename denied")):
            with self.assertRaisesRegex(PermissionError, "rename denied"):
                installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "old")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_launch_failure_keeps_new_app_and_rollback_copy(self):
        app, _ = self.package()
        self.app(self.target, stamp="old")
        installer.launch_mac.side_effect = RuntimeError("launch failed")
        with self.assertRaisesRegex(RuntimeError, "launch failed"):
            installer.install_mac(self.root, app, self.info, self.target)
        self.assertEqual(installer.app_info(self.target, "macos")["CtrlXBuildStamp"], "new-build")
        backup = self.backups()[0]
        self.assertEqual(installer.app_info(backup / "CtrlX.app", "macos")["CtrlXBuildStamp"], "old")
        self.assertEqual(json.loads((backup / installer.storage.RETAINED_MARKER).read_text())["status"], "incomplete")
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_symlink_or_wrong_identity_target_is_not_replaced(self):
        app, _ = self.package()
        self.target.symlink_to(app)
        with self.assertRaisesRegex(ValueError, "non-directory"):
            installer.install_mac(self.root, app, self.info, self.target)
        self.target.unlink()
        self.app(self.target)
        with self.assertRaisesRegex(ValueError, "different bundle ID"):
            installer.install_mac(self.root, app, dict(self.info, CFBundleIdentifier="other"), self.target)
        self.assertEqual(self.backups(), [])

    def test_process_check_ignores_same_named_apps_and_helpers(self):
        executable = self.target / "Contents/MacOS/CtrlX"
        uid = os.getuid()
        installer.run.side_effect = None
        installer.run.return_value.stdout = f"12 {uid} /tmp/CtrlX.app/Contents/MacOS/CtrlX\n13 {uid} {executable}\n14 {uid} {executable}CLI\n"
        self.assertEqual(installer.app_processes(self.target), [13])
        installer.run.return_value.stdout = f"15 {uid + 1} {executable}\n"
        with self.assertRaisesRegex(ValueError, "another user"):
            installer.app_processes(self.target)

    def test_process_inspection_error_fails_closed(self):
        installer.run.side_effect = subprocess.CalledProcessError(1, "ps")
        with self.assertRaises(subprocess.CalledProcessError):
            installer.app_processes(self.target)

    def test_locks_reject_concurrent_install_and_release_after_failure(self):
        path = self.build / "install.lock"
        with self.assertRaisesRegex(RuntimeError, "failure"):
            with installer.install_lock(path):
                with self.assertRaisesRegex(ValueError, "Another local installation"):
                    with installer.install_lock(path):
                        self.fail("acquired twice")
                raise RuntimeError("failure")
        with installer.install_lock(path):
            self.assertTrue(path.exists())

    def test_ios_uses_explicit_device_and_bundle_without_uninstall_or_copy(self):
        app, _ = self.package("ios", "Debug")
        installer.install_ios(app, self.info, DEVICE)
        self.assertEqual(installer.run.call_args_list, [
            mock.call("/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", DEVICE, "--timeout", "180", app),
            mock.call("/usr/bin/xcrun", "devicectl", "device", "process", "launch", "--device", DEVICE,
                      "--timeout", "60", "--terminate-existing", "com.example.ctrlx"),
        ])

    def test_ios_install_failure_does_not_launch(self):
        installer.run.side_effect = subprocess.CalledProcessError(1, "devicectl")
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install_ios(Path("app"), self.info, DEVICE)
        self.assertEqual(installer.run.call_count, 1)

    def test_ios_requires_coredevice_uuid(self):
        with contextlib.redirect_stderr(io.StringIO()):
            for arguments in (["ios"], ["ios", "--device", "iPhone"]):
                with self.assertRaises(SystemExit):
                    installer.parser().parse_args(arguments)

    def workflow(self, arguments, install_error=None):
        installer.run.side_effect = lambda *args, **kwargs: subprocess.CompletedProcess(args, 0, stdout=str(self.root))
        with mock.patch.object(installer, "ROOT", self.root), \
                mock.patch.object(installer.sys, "platform", "darwin"), \
                mock.patch.object(installer.Path, "home", return_value=self.root / "home"), \
                mock.patch.object(installer.build, "built_app", return_value=(Path("app"), self.info)), \
                mock.patch.object(installer, "install_ios", side_effect=install_error), \
                mock.patch.object(installer, "install_mac", side_effect=install_error):
            installer.main(arguments)

    def test_build_then_install_then_cleanup_with_save_space(self):
        self.workflow(["ios", "--device", DEVICE, "--configuration", "Debug", "--save-space"])
        calls = self.children.call_args_list
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0].args[0], ["bash", self.root / "scripts/package-local-ios.sh",
                                         "--app-only", "--configuration", "Debug"])
        self.assertTrue(calls[0].kwargs["defer_cleanup"])
        self.assertIn("--save-space", calls[-1].args[0])
        self.assertIn("prune", calls[-1].args[0])
        self.assertNotIn("--artifact", calls[-1].args[0])
        self.assertEqual(calls[0].args[1], calls[-1].args[1])

    def test_skip_build_still_runs_cleanup(self):
        self.workflow(["macos", "--skip-build"])
        calls = self.children.call_args_list
        self.assertEqual(len(calls), 1)
        self.assertIn("prune", calls[-1].args[0])
        self.assertNotIn("--save-space", calls[-1].args[0])

    def test_install_failure_does_not_prune_caches_or_packages(self):
        with self.assertRaisesRegex(RuntimeError, "install failure"):
            self.workflow(["ios", "--device", DEVICE, "--save-space"], RuntimeError("install failure"))
        self.assertFalse(any("prune" in call.args[0] for call in self.children.call_args_list))


class MacLifecycleTests(unittest.TestCase):
    def test_quit_only_targets_installed_path_and_waits_for_exit(self):
        app = Path("/Applications/CtrlX.app")
        with mock.patch.object(installer, "app_processes", side_effect=[[12], [12], []]), \
                mock.patch.object(installer.subprocess, "run") as run, \
                mock.patch.object(installer.time, "sleep") as sleep:
            installer.quit_mac(app)
        self.assertEqual(run.call_args.args[0], ["/usr/bin/osascript", "-e", f'tell application "{app}" to quit'])
        self.assertEqual(run.call_args.kwargs["timeout"], 45)
        sleep.assert_called_once_with(0.25)

    def test_quit_accepts_cleanup_longer_than_old_fifteen_second_limit(self):
        with mock.patch.object(installer, "app_processes", side_effect=[[12], [12], []]), \
                mock.patch.object(installer.subprocess, "run"), \
                mock.patch.object(installer.time, "monotonic", side_effect=[0, 31]), \
                mock.patch.object(installer.time, "sleep"):
            installer.quit_mac(Path("/Applications/CtrlX.app"))

    def test_no_installed_process_does_not_send_quit(self):
        with mock.patch.object(installer, "app_processes", return_value=[]), \
                mock.patch.object(installer.subprocess, "run") as run:
            installer.quit_mac(Path("/Applications/CtrlX.app"))
        run.assert_not_called()

    def test_quit_request_timeout_never_force_kills(self):
        with mock.patch.object(installer, "app_processes", return_value=[12]), \
                mock.patch.object(installer.subprocess, "run", side_effect=subprocess.TimeoutExpired("osascript", 45)) as run:
            with self.assertRaisesRegex(RuntimeError, "45 seconds; existing App was not replaced"):
                installer.quit_mac(Path("/Applications/CtrlX.app"))
        self.assertEqual(run.call_count, 1)

    def test_quit_timeout_never_force_kills(self):
        with mock.patch.object(installer, "app_processes", return_value=[12]), \
                mock.patch.object(installer.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, stderr="timeout")) as run, \
                mock.patch.object(installer.time, "monotonic", side_effect=[0, 46]):
            with self.assertRaisesRegex(RuntimeError, "not replaced"):
                installer.quit_mac(Path("/Applications/CtrlX.app"))
        self.assertEqual(run.call_count, 1)

    def test_launch_requires_exact_app_process_to_appear(self):
        app = Path("/Applications/CtrlX.app")
        with mock.patch.object(installer, "run") as run, \
                mock.patch.object(installer, "app_processes", side_effect=[[], [123]]), \
                mock.patch.object(installer.time, "sleep"):
            installer.launch_mac(app)
        run.assert_called_once_with("/usr/bin/open", "-a", app)
        with mock.patch.object(installer, "run"), \
                mock.patch.object(installer, "app_processes", return_value=[]), \
                mock.patch.object(installer.time, "monotonic", side_effect=[0, 16]):
            with self.assertRaisesRegex(RuntimeError, "backup was kept"):
                installer.launch_mac(app)

    def test_packaging_metadata_records_the_exact_build_stamp(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-package-metadata-test-") as temporary:
            root = Path(temporary)
            artifact = root / "CtrlX-3.0.58.dmg"
            artifact.write_bytes(b"fixture")
            command = '''source "$1"
get_full_source_revision() { printf revision; }
get_version() { printf 3.0.58; }
get_build_number() { printf 1; }
BUILD_STAMP=20261012-fixture
write_artifact_metadata "$2"
'''
            subprocess.run(["bash", "-c", command, "metadata-test", str(SCRIPT.parent / "common.sh"), str(artifact)],
                           check=True, capture_output=True, text=True)
            manifest = json.loads(Path(str(artifact) + ".manifest.json").read_text())
            self.assertEqual(manifest["buildStamp"], "20261012-fixture")
            self.assertEqual(manifest["sha256"], hashlib.sha256(b"fixture").hexdigest())


if __name__ == "__main__":
    unittest.main()
