#!/usr/bin/env python3
"""System-temp cleanup regressions; all deletion uses disposable fixtures."""
import contextlib
import fcntl
import importlib.util
import io
import os
from pathlib import Path
import plistlib
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


class SystemTempCleanupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ctrlx-system-temp-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "T").mkdir()
        self.now = 3 * storage.SYSTEM_TEMP_MIN_AGE
        self.identifier = "com.ctrlx.embedded-acceptance"
        self.activity = ([], [])

    def file(self, relative):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture")
        return path

    def clone(self, index, identifier=None, timestamp=None):
        identifier = identifier or self.identifier
        path = self.root / "X" / f"{identifier}.code_sign_clone" / f"code_sign_clone.{index:06d}"
        info = self.file(path.relative_to(self.root) / "CtrlX.app.bundle/Contents/Info.plist")
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        modified = index if timestamp is None else timestamp
        os.utime(path, (modified, modified))
        return path

    def old_tree(self, path):
        for child in [*path.rglob("*"), path]:
            os.utime(child, (1, 1), follow_symlinks=False)

    def targets(self):
        return storage.system_temp_targets(self.root, self.activity, self.now)

    def run_cleanup(self, apply=False, snapshots=None):
        with mock.patch.object(storage, "system_temp_root", return_value=self.root), \
                mock.patch.object(storage, "system_temp_activity", side_effect=snapshots,
                                  return_value=self.activity), \
                mock.patch.object(storage.time, "time", return_value=self.now), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            storage.clean_system_temp(apply)
        return output.getvalue()

    def test_preview_and_apply_keep_two_inactive_per_identity_and_all_recent_clones(self):
        groups = [[self.clone(i, identifier) for i in range(5)]
                  for identifier in storage.SIGNING_CLONE_IDS]
        recent = self.clone(8, timestamp=self.now - 60)
        unrelated = self.clone(1, "com.google.Chrome")
        self.assertIn("Preview only", self.run_cleanup())
        self.assertTrue(all(path.exists() for group in groups for path in group))
        self.assertFalse((self.root / "T/ctrlx-system-temp-cleanup.lock").exists())
        self.run_cleanup(apply=True)
        for group in groups:
            keep = group[-1:] if group[0].parent.name.startswith(self.identifier + ".") else group[-2:]
            self.assertTrue(all(path.exists() for path in keep))
            self.assertTrue(all(not path.exists() for path in group if path not in keep))
        self.assertTrue(recent.exists())
        self.assertTrue(unrelated.exists())

    def test_open_clone_and_command_references_do_not_evict_inactive_backups(self):
        paths = [self.clone(i) for i in range(5)]
        self.activity = ([str(paths[0] / "CtrlX.app.bundle/Contents/MacOS/CtrlX")],
                         [f"123 helper --bundle {paths[1]}"])
        self.run_cleanup(apply=True)
        self.assertFalse(paths[2].exists())
        self.assertTrue(all(paths[i].exists() for i in (0, 1, 3, 4)))

    def test_recheck_preserves_a_clone_opened_after_first_snapshot(self):
        paths = [self.clone(i) for i in range(3)]
        self.run_cleanup(apply=True, snapshots=[self.activity, ([str(paths[0] / "open")], [])])
        self.assertTrue(all(path.exists() for path in paths))

    def test_unknown_incomplete_and_wrong_identity_copies_are_preserved(self):
        paths = [self.clone(i) for i in range(3)]
        wrong = self.clone(4)
        (wrong / "CtrlX.app.bundle/Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "another.app"}))
        broken = self.clone(5)
        (broken / "CtrlX.app.bundle/Contents/Info.plist").write_text("broken")
        notes = self.file(paths[0].parent.relative_to(self.root) / "code_sign_clone.notes/evidence.txt")
        extra = self.clone(6)
        (extra / "evidence.txt").write_text("keep")
        partial = self.clone(7)
        (partial / "CtrlX.app.bundle/Contents/Info.plist").write_text('<?xml version="1.0"?><plist><dict>')
        with contextlib.redirect_stderr(io.StringIO()):
            self.run_cleanup(apply=True)
        self.assertFalse(paths[0].exists())
        self.assertTrue(all(path.exists() for path in [*paths[1:], wrong, broken, notes, extra, partial]))

    def test_symlinked_group_aborts_before_any_deletion(self):
        paths = [self.clone(i) for i in range(3)]
        outside = self.file("outside/sentinel")
        (self.root / "X/com.ctrlx.extensions-acceptance.code_sign_clone").symlink_to(outside.parent)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.run_cleanup(apply=True)
        self.assertTrue(all(path.exists() for path in paths))
        self.assertTrue(outside.exists())

    def test_symlinked_identity_is_rejected_but_resource_links_are_not_followed(self):
        paths = [self.clone(i) for i in range(3)]
        outside = self.file("outside/sentinel")
        info = paths[0] / "CtrlX.app.bundle/Contents/Info.plist"
        saved = info.read_bytes()
        info.unlink()
        info.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.run_cleanup(apply=True)
        info.unlink()
        info.write_bytes(saved)
        (info.parent / "Resources").symlink_to(outside.parent)
        self.run_cleanup(apply=True)
        self.assertFalse(paths[0].exists())
        self.assertTrue(outside.exists())

    def test_owner_mismatch_is_rejected(self):
        path = self.clone(1)
        with mock.patch.object(storage.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(ValueError, "current-user"):
                self.targets()
        self.assertTrue(path.exists())

    def legacy_cache(self):
        derived = self.root / "T/ctrlx-e2e-derived-data"
        caches = [self.file(derived.relative_to(self.root) / name / "nested/object.o")
                  for name in (*storage.COMPILATION_CACHE_DIRS, "Index.noindex")]
        keep = [self.file(derived.relative_to(self.root) / name) for name in (
            "Build/Products/Debug/CtrlX.app/executable", "SourcePackages/checkouts/source.swift", "Logs/test.log")]
        self.old_tree(derived)
        return derived, caches, keep

    def test_legacy_cleanup_preserves_products_dependencies_logs_and_unmanaged_temp(self):
        derived, caches, keep = self.legacy_cache()
        keep += [self.file(name) for name in (
            "T/cx-upstream-proof/summary.json", "T/ctrlx-app-update-old/CtrlX.app/executable",
            "C/clang/cache", "T/another-project/Build/Intermediates.noindex/object.o")]
        self.run_cleanup(apply=True)
        self.assertTrue(all(not path.exists() for path in caches))
        self.assertTrue(all(path.exists() for path in keep))
        self.assertTrue(derived.exists())

    def test_legacy_open_product_protects_all_compilation_caches(self):
        _, caches, keep = self.legacy_cache()
        self.activity = ([str(keep[0])], [])
        self.run_cleanup(apply=True)
        self.assertTrue(all(path.exists() for path in caches))

    def test_recent_nested_cache_write_is_kept_even_if_top_directory_is_old(self):
        _, caches, _ = self.legacy_cache()
        os.utime(caches[0], (self.now, self.now))
        self.run_cleanup(apply=True)
        self.assertTrue(caches[0].exists())
        self.assertTrue(all(not path.exists() for path in caches[1:]))

    def test_shared_lock_blocks_second_cleanup(self):
        paths = [self.clone(i) for i in range(3)]
        with (self.root / "T/ctrlx-system-temp-cleanup.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, "Another system-temp cleanup"):
                self.run_cleanup(apply=True)
        self.assertTrue(all(path.exists() for path in paths))

    def test_inspection_error_keeps_all_candidates(self):
        paths = [self.clone(i) for i in range(3)]
        failures = [ValueError("lsof inspection failed"), subprocess.TimeoutExpired("lsof", 40)]
        for error in failures:
            with self.subTest(error=error), self.assertRaises(type(error)):
                self.run_cleanup(apply=True, snapshots=[error])
            self.assertTrue(all(path.exists() for path in paths))

    def test_activity_normalizes_aliases_and_detects_inherited_tmpdir(self):
        base = "/private/var/folders/aa/user/T"
        opened = subprocess.CompletedProcess([], 0, "p123\nn/var/folders/aa/user/T/open/file\n", "")
        with mock.patch.object(storage.subprocess, "check_output", return_value=f"123 helper {base}/command\n"), \
                mock.patch.object(storage.subprocess, "run", return_value=opened), \
                mock.patch.dict(os.environ, {"TMPDIR": "/var/folders/aa/user/T/inherited"}):
            activity = storage.system_temp_activity()
        for name in ("open", "command", "inherited"):
            self.assertTrue(storage.temp_path_in_use(Path(base) / name, activity))
        self.assertFalse(storage.temp_path_in_use(Path(base) / "unrelated", activity))

    def test_lsof_warnings_nonzero_status_and_empty_output_are_errors(self):
        for result in (subprocess.CompletedProcess([], 1, "", ""),
                       subprocess.CompletedProcess([], 0, "p1\nn/file\n", "permission denied"),
                       subprocess.CompletedProcess([], 0, "", "")):
            with self.subTest(result=result), \
                    mock.patch.object(storage.subprocess, "check_output", return_value="123 helper\n"), \
                    mock.patch.object(storage.subprocess, "run", return_value=result), \
                    self.assertRaisesRegex(ValueError, "Cannot inspect"):
                storage.system_temp_activity()

    def test_temp_root_uses_system_location_even_with_nested_inherited_tmpdir(self):
        canonical = Path("/private/var/folders/aa/user/T")
        with mock.patch.object(storage.sys, "platform", "darwin"), \
                mock.patch.object(storage.os, "getuid", return_value=501), \
                mock.patch.dict(os.environ, {"TMPDIR": "/tmp/updater/nested"}), \
                mock.patch.object(storage.subprocess, "check_output", return_value=str(canonical) + "/\n") as command, \
                mock.patch.object(storage.Path, "resolve", return_value=canonical), \
                mock.patch.object(storage, "validate_system_temp_path"):
            self.assertEqual(storage.system_temp_root(), canonical.parent)
        self.assertEqual(command.call_args.args[0], ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"])

    def test_temp_root_rejects_unexpected_location_and_root_user(self):
        with mock.patch.object(storage.sys, "platform", "darwin"), \
                mock.patch.object(storage.os, "getuid", return_value=501), \
                mock.patch.object(storage.subprocess, "check_output", return_value=str(self.root / "T")):
            with self.assertRaisesRegex(ValueError, "Unrecognized macOS"):
                storage.system_temp_root()
        with mock.patch.object(storage.os, "getuid", return_value=0):
            with self.assertRaisesRegex(ValueError, "non-root"):
                storage.system_temp_root()

    def test_e2e_build_default_is_worktree_local_and_explicit_overrides_survive(self):
        source = (SCRIPTS / "e2e-test.sh").read_text()
        configuration = source[source.index('SCRIPT_DIR='):source.index('SIM_NAME=')]
        fixture = self.file("worktree with spaces/scripts/configuration.sh")
        fixture.write_text(configuration + 'printf "%s\\n" "$DERIVED_DATA"\n')
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("REPORT_DERIVED_DATA", "SANDBOX_DERIVED_DATA")}
        environment["TMPDIR"] = str(self.root / "T/updater/nested")
        for overrides, expected in (
            ({}, self.root / "worktree with spaces/.build-local/DerivedData/E2E"),
            ({"SANDBOX_DERIVED_DATA": "/explicit sandbox"}, "/explicit sandbox"),
            ({"REPORT_DERIVED_DATA": "/report", "SANDBOX_DERIVED_DATA": "/sandbox"}, "/report"),
        ):
            with self.subTest(overrides=overrides):
                result = subprocess.run(["bash", str(fixture)], text=True, capture_output=True,
                                        env={**environment, **overrides}, check=True)
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_cli_routes_to_preview_by_default(self):
        paths = [self.clone(i) for i in range(3)]
        with mock.patch.object(sys, "argv", ["clean-build.py", "system-temp"]), \
                mock.patch.object(storage, "system_temp_root", return_value=self.root), \
                mock.patch.object(storage, "system_temp_activity", return_value=self.activity), \
                mock.patch.object(storage.time, "time", return_value=self.now), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            storage.main()
        self.assertIn("Would remove", output.getvalue())
        self.assertTrue(all(path.exists() for path in paths))


if __name__ == "__main__":
    unittest.main()
