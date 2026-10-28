import CtrlxCommon
import CtrlxNetworking
import Foundation
import SwiftUI

/// Persistent window UUIDs keep private resource placement through tmux restarts.
enum IOSTopLevelTabID: Codable, Hashable, Sendable {
    case window(UUID)
    case legacyWindow(String)
    case resource(PaneLinkedTabID)

    init(window: TmuxWindow) {
        if let id = window.panes.first?.workspaceIdentity?.windowID {
            self = .window(id)
        } else {
            self = .legacyWindow(window.stableId)
        }
    }
}

@MainActor
extension IOSPaneLinkedTabs {
    func topLevel(stored: [IOSTopLevelTabID]) -> [IOSTopLevelTabID] {
        PaneLinkedTabs.ordered(windows.map(IOSTopLevelTabID.init(window:)) + items.filter { sourcePaneID($0) == nil }.map(IOSTopLevelTabID.resource), stored: stored)
    }

    func movingTopLevel(_ offsets: IndexSet, to destination: Int, stored: [IOSTopLevelTabID]) -> [IOSTopLevelTabID] {
        let current = topLevel(stored: stored)
        var reordered = current
        reordered.move(fromOffsets: offsets, toOffset: destination)
        var replacement = reordered.makeIterator()
        let members = Set(current)
        return PaneLinkedTabs.ordered(stored + current, stored: stored).map { members.contains($0) ? (replacement.next() ?? $0) : $0 }
    }
}
