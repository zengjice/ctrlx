"""Exercise the production iOS entry reconciliation without operating a live app."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from scripts.tests.test_ios_resource_selection import block

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "CtrlxPackage/Sources/CtrlxFeature"


@unittest.skipUnless(sys.platform == "darwin", "requires the Swift toolchain")
class IOSSessionEntrySelectionTests(unittest.TestCase):
    def test_initial_and_late_catalog_selection(self):
        source = (SOURCES / "Views/WindowLayoutView.swift").read_text()
        method = block(source, "private func reconcileWindowSelection").replace("private func", "func", 1)
        model = (SOURCES / "Models/WindowSelectionReconciliation.swift").read_text()
        fixture = (ROOT / "scripts/tests/fixtures/ios_session_entry.swift").read_text()
        with tempfile.TemporaryDirectory(prefix="ctrlx-session-entry-") as directory:
            build = Path(directory)
            swift = build / "probe.swift"
            swift.write_text(model + "\n" + fixture.replace("// PRODUCTION_METHOD", method))
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(swift), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: eight entry selection scenarios", result.stdout)


if __name__ == "__main__":
    unittest.main()
