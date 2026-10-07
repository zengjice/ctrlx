#!/usr/bin/env python3
"""Test runner/storage policy in disposable worktrees with a fake Swift tool."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent.parent


class UnitTestScriptTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ctrlx-unit-script-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve() / "worktree with spaces"
        scripts = self.root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("unit-tests.sh", "clean-build.py"):
            shutil.copy2(SCRIPTS / name, scripts / name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "CtrlxPackage").mkdir()
        self.log = self.root / "swift-arguments.json"
        tools = self.root / "test-tools"
        tools.mkdir()
        swift = tools / "swift"
        swift.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ["CTRLX_TEST_SWIFT_LOG"]).write_text(json.dumps({"cwd": os.getcwd(), "arguments": sys.argv[1:]}))
build = Path(".build")
build.mkdir(exist_ok=True)
(build / ".buildSystem_debug").write_text("swiftbuild")
sys.exit(int(os.environ["CTRLX_TEST_SWIFT_STATUS"]))
''')
        swift.chmod(0o755)
        self.environment = {
            **os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "CTRLX_TEST_SWIFT_LOG": str(self.log), "CTRLX_TEST_SWIFT_STATUS": "0",
            "NO_COLOR": "1",
        }

    def file(self, name):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture")
        return path

    def run_script(self, *arguments, status=0):
        return subprocess.run([
            "bash", str(self.root / "scripts/unit-tests.sh"), *arguments,
        ], cwd=self.root.parent, env={**self.environment, "CTRLX_TEST_SWIFT_STATUS": str(status)},
            text=True, capture_output=True)

    def test_success_uses_fixed_backend_passes_filters_and_prunes_only_old_caches(self):
        native = self.file("CtrlxPackage/.build/arm64-apple-macosx/debug/object.o")
        index = self.file("CtrlxPackage/.build/out/v5/records/index")
        intermediate = self.file("CtrlxPackage/.build/out/Intermediates.noindex/object.o")
        dependency = self.file("CtrlxPackage/.build/checkouts/dependency.swift")
        result = self.run_script("--", "--filter", "SomeSuite", "--skip-update")
        self.assertEqual(result.returncode, 0, result.stderr)
        invocation = json.loads(self.log.read_text())
        self.assertEqual(invocation["cwd"], str(self.root / "CtrlxPackage"))
        self.assertEqual(invocation["arguments"][:5],
                         ["test", "--parallel", "--build-system", "swiftbuild", "--disable-index-store"])
        self.assertEqual(invocation["arguments"][-3:], ["--filter", "SomeSuite", "--skip-update"])
        self.assertFalse(native.exists())
        self.assertFalse(index.exists())
        self.assertTrue(intermediate.exists())
        self.assertTrue(dependency.exists())

    def test_save_space_only_cleans_after_tests_succeed(self):
        for status in (0, 7):
            with self.subTest(status=status):
                native = self.file("CtrlxPackage/.build/arm64-apple-macosx/debug/object.o")
                index = self.file("CtrlxPackage/.build/out/v5/records/index")
                intermediate = self.file("CtrlxPackage/.build/out/Intermediates.noindex/object.o")
                product = self.file("CtrlxPackage/.build/out/Products/Debug/test.xctest/executable")
                dependency = self.file("CtrlxPackage/.build/checkouts/dependency.swift")
                result = self.run_script("--save-space", "--", "--filter", "SomeSuite", status=status)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(native.exists(), status != 0)
                self.assertEqual(index.exists(), status != 0)
                self.assertEqual(intermediate.exists(), status != 0)
                self.assertTrue(product.exists())
                self.assertTrue(dependency.exists())
                self.assertIn("passed" if status == 0 else "failed", result.stdout)

    def test_managed_options_are_rejected_before_building_or_cleaning(self):
        native = self.file("CtrlxPackage/.build/arm64-apple-macosx/debug/object.o")
        for arguments in (
            ("--build-system", "native"), ("--build-system=native",),
            ("--enable-index-store",), ("--auto-index-store",),
            ("--scratch-path", "/outside"), ("--scratch-path=/outside",),
            ("--package-path", "/outside"), ("--package-path=/outside",),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_script("--", *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("managed by this script", result.stderr)
                self.assertFalse(self.log.exists())
                self.assertTrue(native.exists())

    def test_failed_default_run_keeps_caches_and_reports_original_exit_code(self):
        native = self.file("CtrlxPackage/.build/arm64-apple-macosx/debug/object.o")
        index = self.file("CtrlxPackage/.build/out/v5/records/index")
        result = self.run_script(status=9)
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertIn("failed (exit code: 9)", result.stdout)
        self.assertTrue(native.exists())
        self.assertTrue(index.exists())

    def test_help_and_unknown_flags_do_not_build(self):
        help_result = self.run_script("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("--save-space", help_result.stdout)
        self.assertNotEqual(self.run_script("--unknown").returncode, 0)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
