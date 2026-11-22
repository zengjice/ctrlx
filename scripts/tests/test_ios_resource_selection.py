"""Run iOS resource selection tasks and callbacks in an isolated SwiftUI host."""

import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "CtrlxPackage/Sources/CtrlxFeature/Views/WindowLayoutView.swift"
MODELS = ROOT / "CtrlxPackage/Sources/CtrlxFeature/Models"
FILE_LINK = ROOT / "CtrlxPackage/Sources/CtrlxCommon/UI/TerminalFileLinkAction.swift"


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
    def test_resource_open_and_return(self):
        source = SOURCE.read_text()
        modifiers = block(source, ".task(id: pendingResourceRequest)")
        for selection in ["window?.id", "activePaneId", "fileWorkspace.selectedID",
                          "browserSelection.selectedID", "simulatorSelection.selectedID"]:
            modifiers += "\n" + block(source, f".onChange(of: {selection})")
        methods = "\n".join(
            block(source, marker).removeprefix("private ")
            for marker in (
                "private func fileTabForTerminalLink", "private func openTerminalFile(",
                "private func resourceReturnTarget", "private func returnToLinkedTabSource",
                "private func openResource(", "private var activeResourceReturnPane",
            )
        )
        declarations = "\n".join(
            block(source, f"private {kind} {name}").removeprefix("private ")
            for kind, name in (("struct", "ResourceOpenRequest"), ("enum", "WindowShortcutScope"))
        )
        shortcuts = block(source, "choose: choose ?? { action in")
        shortcuts = shortcuts.replace("choose: choose ?? { action in", "func chooseShortcut(_ action: WindowTabAction, scope: WindowShortcutScope) {", 1)
        actions = block(source, "private func performWindowTabAction(")
        new_resource = actions[actions.index("case let .newResource(kind):"):actions.index("case let .restartAgent")]
        workspace = (MODELS / "IOSFileBrowserWorkspace.swift").read_text()
        return_panes = next(line.strip() for line in workspace.splitlines() if "var resourceReturnPanes:" in line)
        workspace_members = "\n".join((
            return_panes, "@discardableResult", block(workspace, "func adopt("),
            block(workspace, "func syncHostTabs("), block(workspace, "func close("),
        ))
        return_target = block((MODELS / "IOSPaneLinkedTabs.swift").read_text(), "func returnTarget(")
        fixture = (ROOT / "scripts/tests/fixtures/ios_resource_selection.swift").read_text()
        for marker, implementation in {
            "MODIFIERS": modifiers,
            "METHODS": methods,
            "DECLARATIONS": declarations + "\n" + block(FILE_LINK.read_text(), "public struct TerminalFileLinkRequest"),
            "WORKSPACE": workspace_members,
            "RETURN_TARGET": return_target,
            "SHORTCUT": shortcuts,
            "NEW_RESOURCE": new_resource,
        }.items():
            fixture = re.sub(rf"//+ PRODUCTION_{marker}\b", lambda _: implementation, fixture)
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
            self.assertIn("PASS: terminal shortcut retains its return pane; Tabs creation has no return pane", result.stdout)
            self.assertIn("PASS: reused Files returns to the second pane after a catalog gap and session re-entry", result.stdout)
            self.assertIn("PASS: legacy Host receives explicit new Files intent", result.stdout)


if __name__ == "__main__":
    unittest.main()
