"""Run iOS resource selection tasks and callbacks in an isolated SwiftUI host."""

import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "CtrlxPackage/Sources/CtrlxFeature/Views/WindowLayoutView.swift"


def block(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


@unittest.skipUnless(sys.platform == "darwin", "requires SwiftUI and AppKit")
class IOSResourceSelectionTests(unittest.TestCase):
    def test_late_creation_and_legacy_new_files(self):
        source = SOURCE.read_text()
        modifiers = block(source, ".task(id: pendingResourceRequest)")
        for selection in ["window?.id", "activePaneId", "fileWorkspace.selectedID",
                          "browserSelection.selectedID", "simulatorSelection.selectedID"]:
            modifiers += "\n" + block(source, f".onChange(of: {selection})")
        method = block(source, "private func fileTabForTerminalLink").replace("private func", "func", 1)
        fixture = (ROOT / "scripts/tests/fixtures/ios_resource_selection.swift").read_text()
        fixture = fixture.replace("// PRODUCTION_MODIFIERS", modifiers).replace("// PRODUCTION_METHOD", method)
        with tempfile.TemporaryDirectory(prefix="ctrlx-resource-selection-") as directory:
            build = pathlib.Path(directory)
            swift = build / "fixture.swift"
            swift.write_text(fixture)
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(swift), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: 5 selection changes ignore late resource results", result.stdout)
            self.assertIn("PASS: unchanged selection opens the resource", result.stdout)
            self.assertIn("PASS: legacy Host receives explicit new Files intent", result.stdout)


if __name__ == "__main__":
    unittest.main()
