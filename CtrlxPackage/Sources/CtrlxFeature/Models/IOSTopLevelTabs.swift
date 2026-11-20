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

    var sessionTabID: SessionTabID? {
        switch self {
        case let .window(id): .window(id)
        case let .resource(tab): tab.sessionTabID
        case .legacyWindow: nil
        }
    }
}

@MainActor
extension IOSPaneLinkedTabs {
    func topLevel(stored: [IOSTopLevelTabID]) -> [IOSTopLevelTabID] {
        PaneLinkedTabs.ordered(windows.map(IOSTopLevelTabID.init(window:)) + items.filter { sourcePaneID($0) == nil }.map(IOSTopLevelTabID.resource), stored: stored)
    }

    func initialSharedOrder(topLevelOrder: [IOSTopLevelTabID]) -> [SessionTabID] {
        let order = topLevel(stored: topLevelOrder).compactMap(\.sessionTabID)
            + groups.filter { $0.id != nil }.flatMap(\.items).map(\.sessionTabID)
        return order.filter { !isPrivateFile($0) }
    }

    func movingPrivateTab(
        _ source: SessionTabID, before targets: [SessionTabID],
        layout: SessionTabLayout, stored: [IOSTopLevelTabID]
    ) -> [IOSTopLevelTabID]? {
        guard isPrivateFile(source) || (targets.count == 1 && targets.contains(where: isPrivateFile)) else { return nil }
        let entries = sharedEntries(layout, topLevelOrder: stored)
        guard let entry = entries.first(where: { $0.id == .tab(source) }), !targets.contains(source) else { return nil }
        var moved = entries.filter { $0.id != entry.id }
        if let target = targets.first {
            guard let index = moved.firstIndex(where: { $0.tabs.contains(target) }) else { return nil }
            moved.insert(entry, at: index)
        } else {
            moved.append(entry)
        }
        // A local move can only change the positions of private rows.
        let privateRows = Set(entries.compactMap { entry -> SessionTabEntry<SessionTabID>.ID? in
            guard case let .tab(tab) = entry, isPrivateFile(tab) else { return nil }
            return entry.id
        })
        guard moved.map(\.id).filter({ !privateRows.contains($0) }) == entries.map(\.id).filter({ !privateRows.contains($0) }) else { return nil }

        // Save visible group members as anchors using the existing tab IDs.
        let current = windows.map(IOSTopLevelTabID.init(window:)) + items.map(IOSTopLevelTabID.resource)
        let byID = Dictionary(current.compactMap { tab in tab.sessionTabID.map { ($0, tab) } }, uniquingKeysWith: { first, _ in first })
        let order = moved.flatMap(\.tabs).compactMap { byID[$0] }
        return mergingTopLevelOrder(order, into: current, stored: stored)
    }

    func movingTopLevel(_ offsets: IndexSet, to destination: Int, stored: [IOSTopLevelTabID]) -> [IOSTopLevelTabID] {
        let current = topLevel(stored: stored)
        var reordered = current
        reordered.move(fromOffsets: offsets, toOffset: destination)
        return mergingTopLevelOrder(reordered, into: current, stored: stored)
    }

    private func mergingTopLevelOrder(_ order: [IOSTopLevelTabID], into current: [IOSTopLevelTabID], stored: [IOSTopLevelTabID]) -> [IOSTopLevelTabID] {
        var replacement = order.makeIterator()
        let members = Set(order)
        return PaneLinkedTabs.ordered(stored + current, stored: stored).map { members.contains($0) ? (replacement.next() ?? $0) : $0 }
    }
}
