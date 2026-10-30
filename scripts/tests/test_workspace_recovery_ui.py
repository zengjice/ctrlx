"""Keep the production recovery header reachable when many panes need attention."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit")
class WorkspaceRecoveryUITests(unittest.TestCase):
    def test_bounded_details_and_collapse(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-recovery-ui-") as directory:
            build = Path(directory)
            source = (ROOT / "CtrlxPackage/Sources/CtrlxServerFeature/Views/WorkspaceRecoveryStatusView.swift").read_text()
            source = source.split("struct WorkspaceRecoveryWindowAnchor:")[0]
            # Begin expanded; all layout and button actions remain production code.
            initial = "@State private var expanded = false"
            self.assertEqual(source.count(initial), 1)
            source = source.replace(initial, "@State private var expanded = true")
            for identifier in ("workspace-recovery-collapse", "workspace-recovery-keep-all"):
                marker = f'.accessibilityIdentifier("{identifier}")'
                self.assertEqual(source.count(marker), 1)
                source = source.replace(marker, marker + f'\n.background(RecoveryProbe(name: "{identifier}"))')
            production = build / "StatusView.swift"
            production.write_text(source)
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(production),
                 str(ROOT / "scripts/tests/fixtures/workspace_recovery_ui.swift"), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: recovery details scroll, header stays visible and Collapse works", result.stdout)


if __name__ == "__main__":
    unittest.main()
