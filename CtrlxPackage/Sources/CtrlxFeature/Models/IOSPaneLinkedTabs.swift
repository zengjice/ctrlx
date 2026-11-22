import CtrlxCommon
import CtrlxNetworking
import Foundation
import SwiftUI

@MainActor
struct IOSPaneLinkedTabs {
    typealias RowID = SessionTabEntry<SessionTabID>.ID

    enum InsertionLine: Equatable {
        case before(RowID)
        case after(RowID)
    }

    let files: [FileBrowserTab]
    let browsers: [RemoteBrowserTab]
    let simulators: [RemoteSimulatorTab]
    let windows: [TmuxWindow]
    var storedOrder: [PaneLinkedTabID]

    var items: [PaneLinkedTabID] {
        PaneLinkedTabs.ordered(files.map { .file($0.id) } + browsers.map { .browser($0.id) } + simulators.map { .simulator($0.id) }, stored: storedOrder)
    }

    var groups: [PaneLinkedTabs.Group<PaneLinkedTabID>] {
        PaneLinkedTabs.groups(items: items, paneOrder: windows.flatMap(\.panes).map(\.paneId), sourcePane: sourcePaneID)
    }

    func adjacentLinkedTab(_ tab: PaneLinkedTabID, direction: Int, layout: SessionTabLayout?) -> PaneLinkedTabs.Destination<PaneLinkedTabID>? {
        guard let layout else { return PaneLinkedTabs.adjacent(to: tab, direction: direction, groups: groups) }
        let id = tab.sessionTabID
        guard
            abs(direction) == 1,
            case let .group(.pane(pane), members)? = sharedEntries(layout).first(where: { $0.tabs.contains(id) }),
            let index = members.firstIndex(of: id) else { return nil }
        let next = index + direction
        guard members.indices.contains(next) else { return .sourcePane(pane) }
        return items.first { $0.sessionTabID == members[next] }.map(PaneLinkedTabs.Destination.tab)
    }

    func isPrivateFile(_ tab: SessionTabID) -> Bool {
        guard case let .file(id) = tab else { return false }
        return files.contains { $0.id == id && $0.hostTab == nil }
    }

    func sharedMove(
        _ source: SessionTabID, before target: SessionTabID?, layout: SessionTabLayout,
        topLevelOrder: [IOSTopLevelTabID] = []
    ) -> SessionTabLayout.Edit? {
        let entries = sharedEntries(layout, topLevelOrder: topLevelOrder)
        guard let entry = entries.first(where: { $0.tabs.contains(source) }) else { return nil }
        let siblings: [SessionTabID]
        if case let .group(.pane, members) = entry {
            siblings = members
        } else {
            siblings = entries.flatMap { entry -> [SessionTabID] in
                if case .group(.pane, _) = entry {
                    return []
                }
                return entry.tabs
            }
        }
        if let target {
            guard target != source, siblings.contains(target) else { return nil }
            return .move(source, before: target)
        }
        guard let anchor = siblings.last(where: { $0 != source && !isPrivateFile($0) }) else { return nil }
        return .moveToEnd(source, after: anchor)
    }

    static func insertionLine(
        for source: SessionTabID, from current: [SessionTabEntry<SessionTabID>],
        to reordered: [SessionTabEntry<SessionTabID>], expandedGroup: SessionTabGroup?
    ) -> InsertionLine? {
        guard let slot = reordered.firstIndex(where: { $0.tabs.contains(source) }) else { return nil }
        let destination = reordered[slot]
        let currentRows = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        if case let .group(group, members) = destination, let origin = currentRows[destination.id] {
            if group != expandedGroup {
                return .after(origin.id)
            }
            let originalMembers = origin.tabs.filter { $0 != source }
            let originalIDs = Set(originalMembers)
            let memberSlot = members.prefix { $0 != source }.filter(originalIDs.contains).count
            let previous = originalMembers.prefix(memberSlot).last
            return .after(previous.map(RowID.tab) ?? origin.id)
        }

        if destination.sourcePaneID != nil {
            // A restored pane group can only use pane groups already visible in the list as neighbors.
            let previous = reordered[..<slot].reversed().lazy.filter { $0.sourcePaneID != nil }.compactMap { currentRows[$0.id] }.first
            if let previous {
                return .after(lastVisibleRow(in: previous, excluding: destination.tabs, expandedGroup: expandedGroup))
            }
            if let next = reordered.dropFirst(slot + 1).first(where: { $0.sourcePaneID != nil && currentRows[$0.id] != nil }) {
                return .before(next.id)
            }
        }

        let projectedSiblings = reordered.filter { $0.id != destination.id && $0.sourcePaneID == nil }
        let owners = Dictionary(uniqueKeysWithValues: current.flatMap { row in row.tabs.map { ($0, row.id) } })
        let remaining = Set(projectedSiblings.compactMap { row in
            if currentRows[row.id] != nil {
                return row.id
            }
            return row.tabs.lazy.compactMap { owners[$0] }.first
        })
        let siblings = current.filter { remaining.contains($0.id) }
        if let previous = siblings.prefix(slot).last {
            return .after(lastVisibleRow(in: previous, excluding: destination.tabs, expandedGroup: expandedGroup))
        }
        return (siblings.first?.id ?? owners[source]).map(InsertionLine.before)
    }

    private static func lastVisibleRow(
        in entry: SessionTabEntry<SessionTabID>, excluding tabs: [SessionTabID], expandedGroup: SessionTabGroup?
    ) -> RowID {
        if
            case let .group(group, members) = entry, group == expandedGroup,
            let lastMember = members.last(where: { !tabs.contains($0) }) {
            return .tab(lastMember)
        }
        return entry.id
    }

    func sharedEntries(_ layout: SessionTabLayout, topLevelOrder: [IOSTopLevelTabID] = []) -> [SessionTabEntry<SessionTabID>] {
        let resources = Dictionary(items.map { ($0.sessionTabID, $0) }, uniquingKeysWith: { first, _ in first })
        let top = topLevel(stored: topLevelOrder).compactMap(\.sessionTabID)
        let privateFiles = Set(files.filter { $0.hostTab == nil }.map { SessionTabID.file($0.id) })
        let privateTabs = privateFiles.intersection(top)
        let linked = groups.filter { $0.id != nil }.flatMap(\.items).map(\.sessionTabID)
        let catalog = top.filter { !privateTabs.contains($0) } + linked
        let sharedOrder = layout.ordered(catalog)
        let panesByWindow = Dictionary(windows.compactMap { window in
            window.sessionTabID.map { ($0, window.panes.map(\.paneId)) }
        }, uniquingKeysWith: { first, _ in first })
        let paneOrder = sharedOrder.flatMap { panesByWindow[$0, default: []] } + windows.flatMap(\.panes).map(\.paneId)
        let entries = SessionTabEntry.grouped(sharedOrder, paneOrder: paneOrder) { tab in
            if !privateFiles.contains(tab), let group = layout.groups[tab] {
                return .manual(group)
            }
            return resources[tab].flatMap(sourcePaneID).map(SessionTabGroup.pane)
        }.map { entry in
            guard case let .group(.pane(pane), members) = entry, members.contains(where: privateFiles.contains) else { return entry }
            let visible = Set(members)
            var shared = members.filter { !privateFiles.contains($0) }.makeIterator()
            let order = linked.filter(visible.contains).map { privateFiles.contains($0) ? $0 : shared.next() ?? $0 }
            return .group(.pane(pane), order)
        }
        guard !privateTabs.isEmpty else { return entries }

        // A manual group occupies one top-level slot. Automatic groups sit below those slots.
        let topLevel = entries.filter { $0.sourcePaneID == nil }
        let owners = Dictionary(uniqueKeysWithValues: topLevel.flatMap { entry in entry.tabs.map { ($0, entry.id) } })
        let saved = topLevelOrder.compactMap(\.sessionTabID)
        let anchors = PaneLinkedTabs.ordered(top + saved.filter { owners[$0] != nil }, stored: saved)
        var sharedSlots = Set<SessionTabEntry<SessionTabID>.ID>()
        var privateAfter: [Int: [SessionTabEntry<SessionTabID>]] = [:]
        for tab in anchors {
            if privateTabs.contains(tab) {
                privateAfter[sharedSlots.count, default: []].append(.tab(tab))
            } else if let entry = owners[tab] {
                sharedSlots.insert(entry)
            }
        }
        var order: [SessionTabEntry<SessionTabID>] = []
        var slot = 0
        for entry in topLevel {
            if sharedSlots.contains(entry.id) {
                order.append(contentsOf: privateAfter[slot, default: []])
                slot += 1
            }
            order.append(entry)
        }
        order.append(contentsOf: privateAfter[slot, default: []])
        return order + entries.filter { $0.sourcePaneID != nil }
    }

    func sourcePaneID(_ item: PaneLinkedTabID) -> String? {
        switch item {
        case let .file(id): files.first { $0.id == id }?.sourcePaneID
        case let .browser(id): browsers.first { $0.id == id }?.sourcePaneID
        case let .simulator(id): simulators.first { $0.id == id }?.sourcePaneID
        }
    }

    func sourceWindow(for item: PaneLinkedTabID) -> TmuxWindow? {
        guard let sourcePaneID = sourcePaneID(item) else { return nil }
        return windows.first { $0.panes.contains { $0.paneId == sourcePaneID } }
    }

    func returnTarget(for item: PaneLinkedTabID, openedFrom origin: WorkspacePaneIdentity?) -> (paneID: String, window: TmuxWindow)? {
        if let paneID = sourcePaneID(item) {
            return sourceWindow(for: item).map { (paneID, $0) }
        }
        guard let origin else { return nil }
        for window in windows {
            if let pane = window.panes.first(where: { origin.isSamePane(as: $0.workspaceIdentity) }) {
                return (pane.paneId, window)
            }
        }
        return nil
    }

    func title(for source: String?) -> String {
        guard let source else { return "Other" }
        guard
            let window = windows.first(where: { $0.panes.contains { $0.paneId == source } }),
            let pane = window.panes.first(where: { $0.paneId == source }) else { return "Source closed" }
        let name = window.windowName.isEmpty ? "Window \(window.windowIndex)" : window.windowName
        return window.panes.count > 1 ? "\(name) · \(pane.paneIndex + 1)" : name
    }

    func colorKey(for source: String?) -> String? {
        windows.flatMap(\.panes).first { $0.paneId == source }?.workspaceIdentity?.paneID.uuidString ?? source
    }

    func moving(_ source: IndexSet, to destination: Int, in group: PaneLinkedTabs.Group<PaneLinkedTabID>) -> [PaneLinkedTabID] {
        var moved = group.items
        moved.move(fromOffsets: source, toOffset: destination)
        return mergingLinkedOrder(moved)
    }

    func movingPrivateMember(_ source: SessionTabID, before target: SessionTabID, layout: SessionTabLayout) -> [PaneLinkedTabID]? {
        guard
            source != target, isPrivateFile(source) || isPrivateFile(target),
            case let .group(.pane, members)? = sharedEntries(layout).first(where: { $0.tabs.contains(source) }) else { return nil }
        var moved = members.filter { $0 != source }
        guard let index = moved.firstIndex(of: target) else { return nil }
        moved.insert(source, at: index)
        guard moved.filter({ !isPrivateFile($0) }) == members.filter({ !isPrivateFile($0) }) else { return nil }
        let resources = Dictionary(items.map { ($0.sessionTabID, $0) }, uniquingKeysWith: { first, _ in first })
        return mergingLinkedOrder(moved.compactMap { resources[$0] })
    }

    private func mergingLinkedOrder(_ order: [PaneLinkedTabID]) -> [PaneLinkedTabID] {
        var replacement = order.makeIterator()
        let members = Set(order)
        // Keep saved slots for descriptors that have not arrived yet.
        let fullOrder = PaneLinkedTabs.ordered(storedOrder + items, stored: storedOrder)
        return fullOrder.map { members.contains($0) ? (replacement.next() ?? $0) : $0 }
    }
}

extension PaneLinkedTabID {
    var sessionTabID: SessionTabID {
        switch self {
        case let .file(id): .file(id)
        case let .browser(id),
             let .simulator(id): .browser(id)
        }
    }
}

extension TmuxWindow {
    var sessionTabID: SessionTabID? {
        panes.first?.workspaceIdentity.map { .window($0.windowID) }
    }
}
