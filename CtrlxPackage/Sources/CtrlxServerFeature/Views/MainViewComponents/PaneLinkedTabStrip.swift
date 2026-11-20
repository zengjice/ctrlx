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
        SessionTabEntry.grouped(order, paneOrder: paneOrder) { groupID(for: $0)?.paneID.map(SessionTabGroup.pane) }
            .flatMap(\.tabs)
    }

    func presentedTabOrder(_ order: [TabDragPayload], panes: [PaneState], layout: SharedWorkbenchTabLayout.Snapshot?) -> [TabDragPayload] {
        let merged = layout?.order(order, sourcePane: { groupID(for: $0)?.paneID }) ?? order
        let panesByWindow = Dictionary(grouping: panes, by: \.stableWindowId)
        let windows = PaneLinkedTabs.ordered(panes.map(\.stableWindowId), stored: merged.compactMap(\.windowId))
        let paneOrder = windows.flatMap { panesByWindow[$0, default: []].map(\.paneId) }
        return groupedTabOrder(merged, paneOrder: paneOrder)
    }

    func groupID(for tab: TabDragPayload) -> SessionTabGroup? {
        if let id = manualTabGroups[tab] ?? sharedManualTabGroups[tab] {
            return .manual(id)
        }
        return sourcePaneID(for: tab).map(SessionTabGroup.pane)
    }

    func tabStripEntries(_ order: [TabDragPayload]) -> [SessionTabEntry<TabDragPayload>] {
        SessionTabEntry.grouped(order, groupID: groupID(for:))
    }

    func mergeTab(_ source: TabDragPayload, into targets: [TabDragPayload], visible: [TabDragPayload]) -> Bool {
        guard visible.contains(source), !targets.contains(source), let target = targets.first, visible.contains(target) else { return false }
        let group = manualTabGroups[target] ?? UUID()
        for tab in targets + [source] {
            manualTabGroups[tab] = group
        }
        return true
    }

    func reconcileLocalTabGroups(visible order: [TabDragPayload]) {
        guard !manualTabGroups.isEmpty else { return }
        let visible = Set(order)
        let current = manualTabGroups.filter { visible.contains($0.key) }
        let counts = Dictionary(grouping: current.values, by: { $0 })
        let groups = current.filter { (counts[$0.value]?.count ?? 0) > 1 }
        if groups != manualTabGroups {
            manualTabGroups = groups
        }
    }

    func recordTabDrop(_ source: TabDragPayload, at placement: WorkbenchTabDropPlacement) {
        guard tabOrder.contains(source) else { return }
        tabOrder = placement.placing(source, in: tabOrder)
        updateLocalGroup(for: source, at: placement)
    }

    func updateLocalGroup(for source: TabDragPayload, at placement: WorkbenchTabDropPlacement) {
        guard let group = manualTabGroups[source] else { return }
        let leavesGroup = switch placement {
        case let .before(target, _): manualTabGroups[target] != group
        case .end: true
        case .group: false
        }
        if leavesGroup {
            manualTabGroups.removeValue(forKey: source)
            reconcileLocalTabGroups(visible: tabOrder)
        }
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
        groupID(for: source)?.paneID == groupID(for: target)?.paneID
    }
}

extension SessionTabEntry where Tab == TabDragPayload {
    static func navigationDestination(
        from current: Tab, in entries: [Self], direction: Int
    ) -> PaneLinkedTabs.Destination<Tab>? {
        guard direction == -1 || direction == 1 else { return nil }
        if
            case let .group(.pane(id), members)? = entries.first(where: { $0.tabs.contains(current) }),
            let index = members.firstIndex(of: current) {
            let next = index + direction
            return members.indices.contains(next) ? .tab(members[next]) : .sourcePane(id)
        }
        let topLevel = entries.flatMap { entry in
            if case .group(.pane, _) = entry {
                return [Tab]()
            }
            return entry.tabs
        }
        guard topLevel.count > 1, let index = topLevel.firstIndex(of: current) else { return nil }
        return .tab(topLevel[(index + direction + topLevel.count) % topLevel.count])
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

struct PaneLinkedTabStrip<Content: View>: View {
    let order: [TabDragPayload]
    let tabs: SessionFileTabsState?
    let panes: [PaneState]
    let selection: TabDragPayload?
    let rightSide: Bool
    let title: (TabDragPayload) -> String
    let onDrop: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    let onUngroup: (TabDragPayload) -> Void
    @ViewBuilder let content: (TabDragPayload) -> Content

    @State private var expandedGroup: SessionTabGroup?

    var body: some View {
        ForEach(tabs?.tabStripEntries(order) ?? order.map(SessionTabEntry<TabDragPayload>.tab)) { entry in
            switch entry {
            case let .tab(tab): tabTarget(tab)
            case let .group(id, members):
                if let first = members.first {
                    groupButton(id, first: first, members: members)
                }
            }
        }
        .onChange(of: selection) { expandedGroup = nil }
    }

    private func tabTarget(_ tab: TabDragPayload, members: [TabDragPayload]? = nil) -> some View {
        content(tab).modifier(TabGroupDropTarget(
            rightSide: rightSide,
            placement: { members == nil && $0.x >= 16 ? .group([tab]) : .before(tab, within: members) },
            onDrop: onDrop
        ))
    }

    private func groupButton(_ id: SessionTabGroup, first: TabDragPayload, members: [TabDragPayload]) -> some View {
        let name: String
        let color: Color
        switch id {
        case let .pane(paneID):
            let pane = panes.first { $0.paneId == paneID }
            name = groupTitle(pane: pane)
            color = PaneTabGroupStyle.color(for: pane?.workspaceIdentity?.paneID.uuidString ?? paneID)
        case let .manual(uuid):
            name = title(first)
            color = PaneTabGroupStyle.color(for: uuid.uuidString)
        }
        let isSelected = selection.map(members.contains) ?? false
        let countLabel = members.count == 1 ? "1 tab" : "\(members.count.formatted()) tabs"
        return Button { expandedGroup = expandedGroup == id ? nil : id } label: {
            HStack(spacing: 5) {
                Text(name).lineLimit(1).frame(maxWidth: 125)
                Text(members.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                Symbols.chevronDown.image.font(.caption2)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(isSelected ? 0.18 : 0.07), in: .rect(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.55)).allowsHitTesting(false) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 3).padding(.vertical, 3)
        .help("\(name) · \(countLabel)")
        .accessibilityLabel("\(name), \(countLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            if id.paneID == nil {
                Button("Ungroup Tabs") { onUngroup(first) }
            }
        }
        .modifier(TabGroupDropTarget(rightSide: rightSide, placement: { _ in .group(members) }, onDrop: onDrop))
        .popover(isPresented: Binding(get: { expandedGroup == id }, set: {
            if !$0, expandedGroup == id {
                expandedGroup = nil
            }
        }), arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(members, id: \.self) { tab in
                        tabTarget(tab, members: members)
                    }
                }.padding(6)
            }
            .frame(minWidth: 190)
            .frame(height: min(360, CGFloat(members.count) * 39 + 12))
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func groupTitle(pane: PaneState?) -> String {
        guard let pane else { return "Source closed" }
        let name = pane.windowName.isEmpty ? "Window \(pane.windowIndex)" : pane.windowName
        return panes.filter { $0.stableWindowId == pane.stableWindowId }.count > 1
            ? "\(name) · \(pane.paneIndex + 1)" : name
    }
}

private struct TabGroupDropTarget: ViewModifier {
    let rightSide: Bool
    let placement: (CGPoint) -> WorkbenchTabDropPlacement
    let onDrop: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .workbenchDropDestination(rightSide: rightSide, placement: placement) { payloads, destination in
                onDrop(payloads, destination)
            } isTargeted: { targeted = $0 }
    }
}
