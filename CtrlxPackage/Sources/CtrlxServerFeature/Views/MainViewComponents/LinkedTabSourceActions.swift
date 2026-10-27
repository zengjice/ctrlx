import CtrlxCommon
import SwiftUI

/// Source-terminal actions shared by Mac Files, Browser and Simulator tabs.
///
/// A linked tab keeps the pane that created it; these actions must use that
/// pane rather than the window's current selection, which can differ in split
/// layouts or after the user switches terminal tabs.
@MainActor
struct LinkedTabSourceActions {
    var canOpenFiles = true
    var canOpenBrowser = true
    var canOpenSimulator = true
    let onRevealSource: @MainActor (String) -> Void
    let onOpenFiles: @MainActor (String) -> Void
    let onOpenBrowser: @MainActor (String) -> Void
    let onOpenSimulator: @MainActor (String) -> Void

    func menuItems(paneID: String?, isSourceAvailable: Bool, isAgentSource: Bool) -> [ContextMenuItem] {
        let hasSource = paneID != nil && isSourceAvailable

        return [
            .button(
                title: isAgentSource ? "Go to Agent Tab" : "Go to Terminal Tab",
                symbol: isAgentSource ? .sparkles : .terminal,
                isEnabled: hasSource
            ) {
                guard let paneID, isSourceAvailable else { return }
                onRevealSource(paneID)
            },
            .button(title: "Open Files", isEnabled: hasSource && canOpenFiles) {
                guard let paneID, isSourceAvailable else { return }
                onOpenFiles(paneID)
            },
            .button(title: "Open Browser", isEnabled: hasSource && canOpenBrowser) {
                guard let paneID, isSourceAvailable else { return }
                onOpenBrowser(paneID)
            },
            .button(title: "Open iOS Simulator", isEnabled: hasSource && canOpenSimulator) {
                guard let paneID, isSourceAvailable else { return }
                onOpenSimulator(paneID)
            },
        ]
    }
}
