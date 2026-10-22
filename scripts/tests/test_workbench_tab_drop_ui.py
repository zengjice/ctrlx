"""Exercise the production SwiftUI drop destination through AppKit's drag protocol."""

import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "CtrlxPackage/Sources/CtrlxServerFeature/Views/MainViewComponents"


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit")
class WorkbenchTabDropUITests(unittest.TestCase):
    def test_rejected_drop_feedback_and_native_handling(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-tab-drop-ui-") as directory:
            build = pathlib.Path(directory)
            # The payload and its pure extensions share a file with the full tab bar.
            source = (COMPONENTS / "WindowTabBar.swift").read_text()
            payload = build / "TabDragPayload.swift"
            payload.write_text("import SwiftUI\nimport UniformTypeIdentifiers\n" + source[source.index("enum TabDragPayload:"):])
            drag_source = (COMPONENTS / "WorkbenchTabDrag.swift").read_text()
            marker = '.accessibilityIdentifier("workbench-tab-drop-notice")'
            self.assertEqual(drag_source.count(marker), 1)
            drag = build / "WorkbenchTabDrag.swift"
            drag.write_text(drag_source.replace(marker, marker + "\n.background(TabDropNoticeAnchor())"))
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(payload),
                 str(drag), str(COMPONENTS / "WindowTabDragSource.swift"),
                 str(ROOT / "scripts/tests/fixtures/workbench_tab_drop_ui.swift"), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: native drop consumed, no tear-off", result.stdout)


if __name__ == "__main__":
    unittest.main()
