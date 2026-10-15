"""Render the production worktree controls in a private, offscreen AppKit window."""

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCES = ROOT / "CtrlxPackage/Sources"


@unittest.skipUnless(sys.platform == "darwin", "requires AppKit")
class WorktreeStatusUITests(unittest.TestCase):
    def test_narrow_sidebar_and_live_merge_update(self):
        with tempfile.TemporaryDirectory(prefix="ctrlx-worktree-ui-") as directory:
            build = pathlib.Path(directory)
            inputs = []
            for name in (
                "CtrlxNetworking/Models/RepositoryWorktreeStatus.swift",
                "CtrlxCommon/Models/WorktreeStatusSelection.swift",
                "CtrlxCommon/UI/WorktreeStatusView.swift",
            ):
                source = SOURCES / name
                code = source.read_text().replace("import CtrlxNetworking\n", "")
                marker = '.accessibilityIdentifier(pendingOnly ? "worktree-pending-status" : "worktree-list-button")'
                code = code.replace(marker, marker + '\n.background { WorktreeProbeAnchor(id: pendingOnly ? "badge" : "entry") }')
                target = build / source.name
                target.write_text(code)
                inputs.append(str(target))
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(build / "ModuleCache"), *inputs,
                 str(ROOT / "scripts/tests/fixtures/worktree_status_ui.swift"), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: narrow sidebar, separate controls, live merged and unavailable states", result.stdout)


if __name__ == "__main__":
    unittest.main()
