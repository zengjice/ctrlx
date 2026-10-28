import CtrlxCommon
import CtrlxNetworking
import SwiftUI

extension SessionFileTabsState {
    func sourcePaneID(for tab: TabDragPayload) -> String? {
        let source: String?
        switch tab {
        case let .file(id): source = directoryTabs[id]?.sourcePaneID
        case let .browser(id):
            source = remoteSimulatorTabs[id]?.sourcePaneID ?? remoteBrowserTabs[id]?.sourcePaneID
                ?? simulatorStates[id]?.sourcePane?.paneId ?? agentBrowserStates[id]?.paneID
                ?? openBrowserTabs.first(where: { $0.id == id })?.sourcePaneID
        default: source = nil
        }
        return source.flatMap { $0.isEmpty ? nil : $0 }
    }

    func groupedTabOrder(_ order: [TabDragPayload], paneOrder: [String]) -> [TabDragPayload] {
        let children = order.filter { sourcePaneID(for: $0) != nil }
        return order.filter { sourcePaneID(for: $0) == nil }
            + PaneLinkedTabs.groups(items: children, paneOrder: paneOrder, sourcePane: sourcePaneID).flatMap(\.items)
    }

    func recordVisibleTabOrder(_ order: [TabDragPayload]) {
        // A partial catalog must not erase saved slots before those tabs arrive.
        var merged = order
        let visible = Set(order)
        for (index, tab) in tabOrder.enumerated() where tab.isLinkedContent && !visible.contains(tab) {
            merged.insert(tab, at: min(index, merged.count))
        }
        if tabOrder != merged {
            tabOrder = merged
        }
    }

    func restoreLinkedTabOrder(_ saved: [PaneLinkedTabID]?) {
        guard let saved else { return }
        let children = saved.map { id -> TabDragPayload in
            switch id {
            case let .file(id): .file(id)
            case let .browser(id),
                 let .simulator(id): .browser(id)
            }
        }
        let full = PaneLinkedTabs.ordered(tabOrder + children, stored: tabOrder)
        var ordered = PaneLinkedTabs.ordered(full.filter(\.isLinkedContent), stored: children).makeIterator()
        tabOrder = full.map { $0.isLinkedContent ? (ordered.next() ?? $0) : $0 }
    }

    func canReorder(_ source: TabDragPayload, before target: TabDragPayload) -> Bool {
        if sourcePaneID(for: source) == nil, sourcePaneID(for: target) == nil {
            return true
        }
        guard source.isLinkedContent, target.isLinkedContent else { return source.kind == target.kind }
        return sourcePaneID(for: source) == sourcePaneID(for: target)
    }
}

extension TabDragPayload {
    var linkedID: PaneLinkedTabID? {
        switch self {
        case let .file(id): .file(id)
        case let .browser(id): .browser(id)
        default: nil
        }
    }

    var isLinkedContent: Bool {
        switch self {
        case .file,
             .browser: true
        default: false
        }
    }
}

/// Keeps item views intact: selection, drag/drop and close stay with each tab.
struct PaneLinkedTabStrip<Content: View>: View {
    let order: [TabDragPayload]
    let tabs: SessionFileTabsState?
    let panes: [PaneState]
    @ViewBuilder let content: (TabDragPayload) -> Content

    private var groups: [PaneLinkedTabs.Group<TabDragPayload>] {
        PaneLinkedTabs.groups(items: order.filter { tabs?.sourcePaneID(for: $0) != nil }, paneOrder: panes.map(\.paneId)) {
            tabs?.sourcePaneID(for: $0)
        }
    }

    var body: some View {
        ForEach(order.filter { tabs?.sourcePaneID(for: $0) == nil }, id: \.self) { content($0) }
        ForEach(groups) { group in
            let pane = panes.first { $0.paneId == group.id }
            let color = PaneTabGroupStyle.color(for: pane?.workspaceIdentity?.paneID.uuidString ?? group.id)
            HStack(spacing: 0) {
                Text(groupTitle(group.id, pane: pane))
                    .font(.callout)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(maxWidth: 100)
                    .padding(.horizontal, 7)
                ForEach(group.items, id: \.self) { content($0) }
            }
            .clipShape(.rect(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(color.opacity(0.65), lineWidth: 1).allowsHitTesting(false) }
            .padding(.horizontal, 3)
            .padding(.vertical, 3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(groupTitle(group.id, pane: pane))
        }
    }

    private func groupTitle(_ id: String?, pane: PaneState?) -> String {
        guard id != nil else { return "Other" }
        guard let pane else { return "Source closed" }
        let name = pane.windowName.isEmpty ? "Window \(pane.windowIndex)" : pane.windowName
        return panes.filter { $0.stableWindowId == pane.stableWindowId }.count > 1
            ? "\(name) · \(pane.paneIndex + 1)" : name
    }
}
