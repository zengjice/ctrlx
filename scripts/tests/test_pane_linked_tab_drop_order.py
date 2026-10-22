"""Run the Mac tab bars' actual drop handlers against a partial tab catalog."""

import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPONENTS = ROOT / "CtrlxPackage/Sources/CtrlxServerFeature/Views/MainViewComponents"


def declaration(source, marker):
    """Copy a complete production declaration, including its unchanged body."""
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise ValueError(f"Unclosed declaration: {marker}")


@unittest.skipUnless(sys.platform == "darwin", "requires the Mac tab payload's SwiftUI types")
class PaneLinkedTabDropOrderTests(unittest.TestCase):
    def test_partial_catalog_survives_all_drop_entry_points(self):
        local = (COMPONENTS / "WindowTabBar.swift").read_text()
        remote = (COMPONENTS / "RemoteWindowTabBar.swift").read_text()
        linked = (COMPONENTS / "PaneLinkedTabStrip.swift").read_text()
        source = "import SwiftUI\nimport UniformTypeIdentifiers\n"
        source += local[local.index("enum TabDragPayload:"):]
        source += "\nextension TabDragPayload {\n" + declaration(linked, "var isLinkedContent:") + "\n}\n"
        source += """
@MainActor final class Tabs {
    var tabOrder: [TabDragPayload] = []
    var isWindowReorderPending = false
    // All fixture children belong to the same source pane.
    func sourcePaneID(for tab: TabDragPayload) -> String? { "%1" }
"""
        for marker in ("func recordVisibleTabOrder(", "func canReorder("):
            source += declaration(linked, marker) + "\n"
        source += """
}
struct Window { let stableId: String }
struct Session { let windows = [Window(stableId: "@1")] }
enum TabSection: String { case single, left, right }
"""
        for name, view, optional in (("Local", local, ""), ("Remote", remote, "?")):
            source += f"""
@MainActor final class {name} {{
    let sessionTabs: Tabs{optional}
    init(_ tabs: Tabs) {{ sessionTabs = tabs }}
    var dropIndicator: TabDragPayload?
    var trailingDropTargetedSection: TabSection?
    let session = Session()
    var windows: [Window] {{ session.windows }}
    var effectiveTabOrder: [TabDragPayload] = []
    var synchronizedOrder: [TabDragPayload] = []
    func isOnRight(_ tab: TabDragPayload) -> Bool {{ false }}
    func sectionOf(_ tab: TabDragPayload) -> TabSection {{ .single }}
    func adjustSplitSideIfNeeded(source: TabDragPayload, to section: TabSection) {{}}
    func syncSubsequences(from order: [TabDragPayload], rollbackOrder: [TabDragPayload]) {{
        synchronizedOrder = order
    }}
    func drop(_ a: TabDragPayload, _ b: TabDragPayload, destination: String) -> Bool {{
        if let section = TabSection(rawValue: destination) {{
            return handleEndDrop(payloads: [a], section: section)
        }}
        return handleDrop(payloads: [b], target: a)
    }}
"""
            for marker in ("private func handleDrop(", "private func handleEndDrop("):
                source += declaration(view, marker) + "\n"
            source += "}\n"
        source += """
struct Failure: Error { let message: String }
@main struct Probe {
    @MainActor static func main() {
        do { try run() } catch {
            print("FAIL: \\(error)")
            exit(1)
        }
    }
    @MainActor static func run() throws {
        let mode = CommandLine.arguments[1], destination = CommandLine.arguments[2]
        let a = TabDragPayload.file(UUID()), b = TabDragPayload.file(UUID())
        let window = TabDragPayload.window("@1")
        for delayed in [TabDragPayload.browser(UUID()), .file(UUID())] {
            let tabs = Tabs()
            tabs.tabOrder = [window, a, delayed, b]
            let visible = [window, a, b], moved = [window, b, a]
            let expected = [window, b, delayed, a]
            let accepted: Bool, synchronized: [TabDragPayload]
            if mode == "local" {
                let bar = Local(tabs)
                bar.effectiveTabOrder = visible
                accepted = bar.drop(a, b, destination: destination)
                synchronized = bar.synchronizedOrder
            } else {
                let bar = Remote(tabs)
                bar.effectiveTabOrder = visible
                accepted = bar.drop(a, b, destination: destination)
                synchronized = bar.synchronizedOrder
            }
            guard accepted, synchronized == moved, tabs.tabOrder == expected else {
                throw Failure(message: "Drop erased a delayed slot or synchronized a missing tab")
            }
            // SwiftUI subsequently observes only the visible order. Save it,
            // restore it, then deliver the missing descriptor.
            tabs.recordVisibleTabOrder(moved)
            let saved = try JSONEncoder().encode(tabs.tabOrder)
            let restored = try JSONDecoder().decode([TabDragPayload].self, from: saved)
            let fileIDs = expected.compactMap { if case let .file(id) = $0 { id } else { nil } }
            let browserIDs = expected.compactMap { if case let .browser(id) = $0 { id } else { nil } }
            let arrived = TabDragPayload.reconciledOrder(
                windowIds: ["@1"], fileTabIds: fileIDs, browserTabIds: browserIDs,
                storedOrder: restored, includeFileExplorer: false, includeGit: false
            )
            guard arrived == expected else { throw Failure(message: "Delayed tab lost its saved slot") }
        }
        print("PASS: delayed file/browser slots preserved")
    }
}
"""
        with tempfile.TemporaryDirectory(prefix="ctrlx-tab-drop-order-") as directory:
            build = pathlib.Path(directory)
            probe = build / "Probe.swift"
            probe.write_text(source)
            executable = build / "probe"
            result = subprocess.run(
                ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                 "-module-cache-path", str(build / "ModuleCache"), str(probe), "-o", str(executable)],
                capture_output=True, text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for mode in ("local", "remote"):
                for destination in ("target", "single", "left", "right"):
                    with self.subTest(mode=mode, destination=destination):
                        result = subprocess.run(
                            [str(executable), mode, destination],
                            capture_output=True, text=True, timeout=10,
                        )
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertIn("PASS: delayed file/browser slots preserved", result.stdout)


if __name__ == "__main__":
    unittest.main()
