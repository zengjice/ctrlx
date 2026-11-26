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

    func localTabPanes(sessionName: String, windows: [LocalTmuxWindow], paneStates: [String: PaneState]) -> [PaneState] {
        let ids = PaneLinkedTabs.ordered(windows.map(\.stableId), stored: tabOrder.compactMap(\.windowId))
        let visible = ids.flatMap { id in windows.first { $0.stableId == id }?.panes ?? [] }
            .compactMap { paneStates[$0.paneId] }
        let seen = Set(visible.map(\.paneId))
        return visible + paneStates.values.filter { $0.sessionName == sessionName && !seen.contains($0.paneId) }
            .sorted { ($0.windowIndex, $0.paneIndex) < ($1.windowIndex, $1.paneIndex) }
    }

    func localPresentedTabOrder(windows: [LocalTmuxWindow], panes: [PaneState], layout: SharedWorkbenchTabLayout.Snapshot?) -> [TabDragPayload] {
        let order = TabDragPayload.reconciledOrder(
            windowIds: windows.map(\.stableId),
            fileTabIds: openFileTabs.map(\.id),
            browserTabIds: openBrowserTabs.map(\.id),
            storedOrder: tabOrder,
            includeFileExplorer: false
        )
        return presentedTabOrder(order, panes: panes, layout: layout)
    }

    func groupedTabOrder(_ order: [TabDragPayload], paneOrder: [String], sourcePane: ((TabDragPayload) -> String?)? = nil) -> [TabDragPayload] {
        let pane = sourcePane ?? { self.groupID(for: $0)?.paneID }
        return SessionTabEntry.grouped(order, paneOrder: paneOrder) { pane($0).map(SessionTabGroup.pane) }
            .flatMap(\.tabs)
    }

    func presentedTabOrder(_ order: [TabDragPayload], panes: [PaneState], layout: SharedWorkbenchTabLayout.Snapshot?) -> [TabDragPayload] {
        let sharedGroups = layout?.groups ?? [:]
        func sourcePane(_ tab: TabDragPayload) -> String? {
            guard manualTabGroups[tab] == nil, sharedGroups[tab] == nil else { return nil }
            return sourcePaneID(for: tab)
        }
        let merged = layout?.order(order, sourcePane: sourcePane) ?? order
        return groupedTabOrder(merged, paneOrder: Self.paneOrder(for: merged, panes: panes), sourcePane: sourcePane)
    }

    static func paneOrder(for order: [TabDragPayload], panes: [PaneState]) -> [String] {
        let panesByWindow = Dictionary(grouping: panes, by: \.stableWindowId)
        let windows = PaneLinkedTabs.ordered(panes.map(\.stableWindowId), stored: order.compactMap(\.windowId))
        return windows.flatMap { panesByWindow[$0, default: []].map(\.paneId) }
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

    func panesAfterDrop(
        _ order: [TabDragPayload], hover: WorkbenchTabHover, shared: SharedWorkbenchTabLayout.Snapshot?, leavesSharedGroup: Bool
    ) -> [TabDragPayload: String] {
        let leavingLocal = leavesSharedGroup || localGroup(for: hover.tab, after: hover.placement) == nil ? hover.tab : nil
        let sharedSource = hover.sharedTabID ?? shared?.ids[hover.tab]

        func hasGroupPeer<ID: Hashable>(_ member: ID, excluding source: ID?, in memberships: [ID: UUID]) -> Bool {
            guard member != source, let group = memberships[member] else { return false }
            return memberships.contains { $0.value == group && $0.key != member && $0.key != source }
        }

        var panes: [TabDragPayload: String] = [:]
        for tab in order {
            guard
                let pane = tab == hover.tab ? hover.sourcePaneID : sourcePaneID(for: tab),
                !hasGroupPeer(tab, excluding: leavingLocal, in: manualTabGroups) else { continue }
            let hasSharedPeer: Bool
            if let shared, let id = tab == hover.tab ? sharedSource : shared.ids[tab] {
                hasSharedPeer = hasGroupPeer(id, excluding: leavesSharedGroup ? sharedSource : nil, in: shared.layout.groups)
            } else {
                hasSharedPeer = hasGroupPeer(tab, excluding: leavesSharedGroup ? hover.tab : nil, in: sharedManualTabGroups)
            }
            if !hasSharedPeer {
                panes[tab] = pane
            }
        }
        return panes
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
        if manualTabGroups[source] != nil, localGroup(for: source, after: placement) == nil {
            manualTabGroups.removeValue(forKey: source)
            reconcileLocalTabGroups(visible: tabOrder)
        }
    }

    func localGroup(for source: TabDragPayload, after placement: WorkbenchTabDropPlacement) -> UUID? {
        guard let group = manualTabGroups[source] else { return nil }
        return switch placement {
        case let .before(target, _),
             let .after(target, _): manualTabGroups[target] == group ? group : nil
        case .end: nil
        case .group: group
        }
    }

    func tabOrderKeepingHiddenLinks(_ order: [TabDragPayload]) -> [TabDragPayload] {
        // A partial catalog must not erase saved slots before those tabs arrive.
        var merged = order
        let visible = Set(order)
        for (index, tab) in tabOrder.enumerated() where tab.isLinkedContent && !visible.contains(tab) {
            merged.insert(tab, at: min(index, merged.count))
        }
        return merged
    }

    func recordVisibleTabOrder(_ order: [TabDragPayload]) {
        let merged = tabOrderKeepingHiddenLinks(order)
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

struct PaneLinkedTabStrip<Content: View, Accessory: View>: View {
    let order: [TabDragPayload]
    let sessionOrder: [TabDragPayload]
    let tabs: SessionFileTabsState?
    let panes: [PaneState]
    let paneOrder: [String]
    let selection: TabDragPayload?
    let rightSide: Bool
    let title: (TabDragPayload) -> String
    let onDrop: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    let onEndDrop: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    let onUngroup: (TabDragPayload) -> Void
    let trailingDropID: String
    @ViewBuilder let content: (TabDragPayload) -> Content
    @ViewBuilder let accessory: () -> Accessory

    @Environment(\.workbenchTabContext) private var workbenchContext
    @State private var expandedGroup: SessionTabGroup?
    @State private var hoveredInsertion: WorkbenchTabHover?

    private var entries: [SessionTabEntry<TabDragPayload>] {
        tabs?.tabStripEntries(order) ?? order.map(SessionTabEntry<TabDragPayload>.tab)
    }

    private var insertion: TabStripInsertion? {
        hoveredInsertion.flatMap { hover in
            TabStripInsertion.resolve(
                hover, order: order, tabs: tabs, paneOrder: paneOrder,
                shared: workbenchContext?.sharedTabLayout, sessionOrder: sessionOrder
            )
        }
    }

    var body: some View {
        let marker = insertion
        ForEach(entries) { entry in
            Group {
                switch entry {
                case let .tab(tab): tabTarget(tab)
                case let .group(id, members):
                    if let first = members.first {
                        groupButton(id, first: first, members: members)
                    }
                }
            }
            .overlay(alignment: marker?.side == .after ? .trailing : .leading) {
                if marker?.row == entry.id {
                    DropInsertionIndicator(axis: .horizontal)
                }
            }
        }
        .onChange(of: selection) { expandedGroup = nil }
        accessory()
        trailingDropZone
    }

    private var trailingDropZone: some View {
        let placement = WorkbenchTabDropPlacement.end(entries.flatMap(\.tabs))
        return Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if entries.isEmpty, case .end = hoveredInsertion?.placement {
                    DropInsertionIndicator(axis: .horizontal)
                        .padding(.leading, 4)
                }
            }
            .workbenchDropDestination(rightSide: rightSide, placement: { _ in placement }, action: onEndDrop) { hover in
                if let hover {
                    hoveredInsertion = hover
                } else if case .end = hoveredInsertion?.placement {
                    hoveredInsertion = nil
                }
            }
            .accessibilityElement()
            .accessibilityIdentifier(trailingDropID)
            .accessibilityLabel("Tab strip trailing drop zone")
    }

    private func tabTarget(_ tab: TabDragPayload, members: [TabDragPayload]? = nil) -> some View {
        content(tab).modifier(TabGroupDropTarget(
            rightSide: rightSide,
            axis: members == nil ? .horizontal : .vertical,
            placement: { position, length in
                let side = members == nil ? InsertionSide.tabEdge(position: position, length: length) : InsertionSide(position: position, length: length)
                switch side {
                case .before: return .before(tab, within: members)
                case .after: return .after(tab, within: members)
                case nil: return .group([tab])
                }
            },
            onDrop: onDrop,
            onInsertionHover: members == nil ? { updateInsertion($0, at: tab) } : nil
        ))
    }

    private func updateInsertion(_ hover: WorkbenchTabHover?, at tab: TabDragPayload) {
        if let hover {
            if hoveredInsertion != hover {
                hoveredInsertion = hover
            }
        } else {
            switch hoveredInsertion?.placement {
            case .before(tab, _),
                 .after(tab, _): hoveredInsertion = nil
            default: break
            }
        }
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
        .modifier(TabGroupDropTarget(rightSide: rightSide, axis: .horizontal, placement: { _, _ in .group(members) }, onDrop: onDrop))
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

struct TabStripInsertion: Equatable {
    let row: SessionTabEntry<TabDragPayload>.ID
    let side: InsertionSide

    @MainActor
    static func resolve(
        _ hover: WorkbenchTabHover, order: [TabDragPayload], tabs: SessionFileTabsState?, paneOrder: [String],
        shared: SharedWorkbenchTabLayout? = nil, sessionOrder: [TabDragPayload]? = nil
    ) -> Self? {
        if case .group = hover.placement {
            return nil
        }
        let entries = tabs?.tabStripEntries(order) ?? order.map(SessionTabEntry<TabDragPayload>.tab)
        let proposed = hover.placement.placing(hover.tab, in: order)
        let leavesSharedGroup = shared?.leavesGroupOnDrop(
            hover.tab, at: hover.placement, order: sessionOrder ?? order, incomingID: hover.sharedTabID
        ) == true
        let panes = tabs?.panesAfterDrop(proposed, hover: hover, shared: shared?.snapshot, leavesSharedGroup: leavesSharedGroup) ?? [:]
        if let pane = panes[hover.tab] {
            return paneInsertion(pane, entries: entries, proposed: proposed, panes: panes, paneOrder: paneOrder)
        }

        switch hover.placement {
        case let .before(tab, _) where panes[tab] == nil: return .init(row: .tab(tab), side: .before)
        case let .after(tab, _) where panes[tab] == nil: return .init(row: .tab(tab), side: .after)
        case let .end(targets):
            guard targets.contains(where: { $0 != hover.tab }) || !order.contains(hover.tab) else { return nil }
        default: break
        }

        let topLevel = proposed.filter { panes[$0] == nil }
        if let index = topLevel.firstIndex(of: hover.tab) {
            if index > 0, let previous = entries.first(where: { $0.tabs.contains(topLevel[index - 1]) }) {
                return .init(row: previous.id, side: .after)
            }
            if index + 1 < topLevel.count, let next = entries.first(where: { $0.tabs.contains(topLevel[index + 1]) }) {
                return .init(row: next.id, side: .before)
            }
        }
        return entries.first.map { .init(row: $0.id, side: .before) }
    }

    private static func paneInsertion(
        _ pane: String, entries: [SessionTabEntry<TabDragPayload>],
        proposed: [TabDragPayload], panes: [TabDragPayload: String], paneOrder: [String]
    ) -> Self? {
        let restored = SessionTabGroup.pane(pane)
        if entries.contains(where: { $0.id == .group(restored) }) {
            return .init(row: .group(restored), side: .after)
        }
        let lastTopLevel = entries.lastIndex { $0.tabs.contains { panes[$0] == nil } }
        let paneRows = lastTopLevel.map { entries.suffix(from: $0 + 1) } ?? entries[...]
        func visibleEntry(for pane: String) -> SessionTabEntry<TabDragPayload>? {
            paneRows.first { entry in entry.tabs.contains { panes[$0] == pane } }
        }
        let automatic = PaneLinkedTabs.ordered(proposed.compactMap { panes[$0] }, stored: paneOrder)
        if let index = automatic.firstIndex(of: pane) {
            let existingPanes = Set(paneRows.compactMap(\.sourcePaneID))
            if let previous = automatic[..<index].last(where: existingPanes.contains) {
                return .init(row: .group(.pane(previous)), side: .after)
            }
            if let next = automatic.dropFirst(index + 1).first(where: existingPanes.contains) {
                return .init(row: .group(.pane(next)), side: .before)
            }
            if index > 0, let previous = visibleEntry(for: automatic[index - 1]) {
                return .init(row: previous.id, side: .after)
            }
            if index + 1 < automatic.count, let next = visibleEntry(for: automatic[index + 1]) {
                return .init(row: next.id, side: .before)
            }
        }
        if let lastTopLevel {
            return .init(row: entries[lastTopLevel].id, side: .after)
        }
        return entries.first.map { .init(row: $0.id, side: .before) }
    }
}

private struct TabGroupDropTarget: ViewModifier {
    let rightSide: Bool
    let axis: Axis
    let placement: (CGFloat, CGFloat) -> WorkbenchTabDropPlacement
    let onDrop: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    var onInsertionHover: ((WorkbenchTabHover?) -> Void)? = nil
    @State private var length: CGFloat = 0
    @State private var hoveredPlacement: WorkbenchTabDropPlacement?

    func body(content: Content) -> some View {
        content
            .overlay {
                if case .group = hoveredPlacement {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .overlay(alignment: insertionAlignment) {
                if onInsertionHover == nil {
                    switch hoveredPlacement {
                    case .before,
                         .after: DropInsertionIndicator(axis: axis)
                    default: EmptyView()
                    }
                }
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                length = axis == .horizontal ? size.width : size.height
            }
            .workbenchDropDestination(rightSide: rightSide, placement: { point in
                placement(axis == .horizontal ? point.x : point.y, length)
            }) { payloads, destination in
                onDrop(payloads, destination)
            } onHover: { hover in
                let placement = hover?.placement
                if hoveredPlacement != placement {
                    hoveredPlacement = placement
                }
                if case .group = placement {
                    onInsertionHover?(nil)
                } else {
                    onInsertionHover?(hover)
                }
            }
    }

    private var insertionAlignment: Alignment {
        if case .after = hoveredPlacement {
            return axis == .horizontal ? .trailing : .bottom
        }
        return axis == .horizontal ? .leading : .top
    }
}
