import CtrlxCommon
import CtrlxNetworking
import Foundation
import SwiftUI

@MainActor
struct IOSPaneLinkedTabs {
    let files: [FileBrowserTab]
    let browsers: [RemoteBrowserTab]
    let simulators: [RemoteSimulatorTab]
    let windows: [TmuxWindow]
    let storedOrder: [PaneLinkedTabID]

    var items: [PaneLinkedTabID] {
        PaneLinkedTabs.ordered(files.map { .file($0.id) } + browsers.map { .browser($0.id) } + simulators.map { .simulator($0.id) }, stored: storedOrder)
    }

    var groups: [PaneLinkedTabs.Group<PaneLinkedTabID>] {
        PaneLinkedTabs.groups(items: items, paneOrder: windows.flatMap(\.panes).map(\.paneId), sourcePane: sourcePaneID)
    }

    func sourcePaneID(_ item: PaneLinkedTabID) -> String? {
        switch item {
        case let .file(id): files.first { $0.id == id }?.sourcePaneID
        case let .browser(id): browsers.first { $0.id == id }?.sourcePaneID
        case let .simulator(id): simulators.first { $0.id == id }?.sourcePaneID
        }
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
        var replacement = moved.makeIterator()
        let members = Set(group.items)
        // Keep saved slots for descriptors that have not arrived yet.
        let fullOrder = PaneLinkedTabs.ordered(storedOrder + items, stored: storedOrder)
        return fullOrder.map { members.contains($0) ? (replacement.next() ?? $0) : $0 }
    }
}
