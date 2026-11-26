import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var ctrlxWorkbenchTab: UTType {
        UTType(exportedAs: "com.jicezeng.ctrlx.workbench-tab")
    }
}

struct WorkbenchTabDrag: Codable, Sendable {
    @MainActor static var active: (tab: TabDragPayload, context: Self?)?

    let workspaceID: UUID?
    let hostID: String?
    let sessionName: String
    let tab: TabDragPayload
    var group: [TabDragPayload]? = nil
}

struct WorkbenchTabHover: Equatable {
    let tab: TabDragPayload
    let placement: WorkbenchTabDropPlacement
    let sourcePaneID: String?
    var sharedTabID: SessionTabID? = nil
    var group: [TabDragPayload]? = nil
}

extension TabDragPayload {
    var canDetach: Bool {
        switch self {
        case .window,
             .file,
             .browser: true
        case .git,
             .fileExplorer: false
        }
    }
}

enum WorkbenchTabDropPlacement: Equatable, Sendable {
    case before(TabDragPayload, within: [TabDragPayload]? = nil)
    case after(TabDragPayload, within: [TabDragPayload]? = nil)
    case group([TabDragPayload])
    case end([TabDragPayload])

    var targets: [TabDragPayload] {
        switch self {
        case let .before(target, _),
             let .after(target, _): [target]
        case let .group(targets),
             let .end(targets): targets
        }
    }

    func placing(_ source: TabDragPayload, in order: [TabDragPayload]) -> [TabDragPayload] {
        var result = order.filter { $0 != source }
        let index: Int? = switch self {
        case let .before(target, _): result.firstIndex(of: target)
        case let .after(target, _): result.firstIndex(of: target).map { $0 + 1 }
        case let .group(targets): result.lastIndex(where: targets.contains).map { $0 + 1 }
        case let .end(targets):
            targets.reversed().lazy.compactMap { result.firstIndex(of: $0) }.first.map { $0 + 1 }
                ?? order.firstIndex(of: source)
        }
        result.insert(source, at: index ?? result.endIndex)
        return result
    }

    func accepts(_ source: TabDragPayload) -> Bool {
        switch self {
        case let .before(target, members),
             let .after(target, members):
            source != target && (members?.contains(source) ?? true)
        case let .group(targets):
            !targets.contains(source)
        case .end:
            true
        }
    }

    func groupTarget(in entries: [SessionTabEntry<TabDragPayload>]) -> TabDragPayload? {
        switch self {
        case let .before(target, _): return entries.first { $0.tabs.contains(target) }?.tabs.first
        case let .after(target, _):
            guard let index = entries.firstIndex(where: { $0.tabs.contains(target) }) else { return nil }
            return entries.dropFirst(index + 1).first?.tabs.first
        case .end: return nil
        case .group: return nil
        }
    }

    func movingGroup(_ members: [TabDragPayload], in entries: [SessionTabEntry<TabDragPayload>]) -> [SessionTabEntry<TabDragPayload>]? {
        switch self {
        case let .before(target, _),
             let .after(target, _):
            guard entries.contains(where: { $0.tabs.contains(target) }) else { return nil }
        case .end: break
        case .group: return nil
        }
        guard
            let reordered = SessionTabEntry.movingGroup(members, before: groupTarget(in: entries), in: entries),
            reordered.map(\.id) != entries.map(\.id) else { return nil }
        return reordered
    }
}

@MainActor
struct WorkbenchTabContext {
    let workspaceID: UUID?
    let hostID: String?
    let sessionName: String
    let onRejected: () -> Void
    var detach: ((WorkbenchTabDrag, CGPoint?) -> Void)? = nil
    var returnToMain: ((WorkbenchTabDrag) -> Void)? = nil
    var sharedTabLayout: SharedWorkbenchTabLayout? = nil
    var sourcePaneGroup: (WorkbenchTabDrag) -> String? = { _ in nil }
    var sourcePaneID: (WorkbenchTabDrag) -> String? = { _ in nil }
    var incomingSharedTabID: (WorkbenchTabDrag) -> SessionTabID? = { _ in nil }
    var canTransfer: (WorkbenchTabDrag) -> Bool = { _ in true }
    let receive: (WorkbenchTabDrag, WorkbenchTabDropPlacement, Bool) -> Bool

    func detachmentMenuItems(for tab: TabDragPayload) -> [ContextMenuItem] {
        guard tab.canDetach, let detach else { return [] }
        return [.button(title: "Open in Separate Window") { detach(drag(tab), nil) }]
    }

    func drag(_ tab: TabDragPayload) -> WorkbenchTabDrag {
        WorkbenchTabDrag(workspaceID: workspaceID, hostID: hostID, sessionName: sessionName, tab: tab)
    }

    func accepts(_ drag: WorkbenchTabDrag) -> Bool {
        drag.hostID == hostID && drag.sessionName == sessionName
    }

    func resolvedPlacement(_ drag: WorkbenchTabDrag, at placement: WorkbenchTabDropPlacement) -> WorkbenchTabDropPlacement? {
        if let group = drag.group {
            guard accepts(drag), drag.workspaceID == workspaceID, !group.isEmpty else { return nil }
            switch placement {
            case let .before(target, nil),
                 let .after(target, nil): return group.contains(target) ? nil : placement
            case .end: return placement
            default: return nil
            }
        }
        guard
            accepts(drag), placement.accepts(drag.tab),
            drag.workspaceID == workspaceID || canTransfer(drag) else { return nil }
        let group = sourcePaneGroup(drag)
        switch placement {
        case let .before(target, _),
             let .after(target, _):
            return sourcePaneGroup(self.drag(target)) == group ? placement : nil
        case .group:
            return placement
        case let .end(tabs):
            return .end(tabs.filter { sourcePaneGroup(self.drag($0)) == group })
        }
    }

    func drop(_ drag: WorkbenchTabDrag, at placement: WorkbenchTabDropPlacement, rightSide: Bool, reorder: (WorkbenchTabDropPlacement) -> Bool) -> Bool {
        guard let destination = resolvedPlacement(drag, at: placement) else {
            if !accepts(drag) {
                onRejected()
            }
            // Consume the drop so AppKit does not detach the rejected tab.
            return true
        }
        if drag.workspaceID != workspaceID {
            return receive(drag, destination, rightSide)
        }
        return reorder(destination)
    }

    func hover(_ drag: WorkbenchTabDrag, at placement: WorkbenchTabDropPlacement) -> WorkbenchTabHover? {
        guard let destination = resolvedPlacement(drag, at: placement) else { return nil }
        return WorkbenchTabHover(
            tab: drag.tab, placement: destination, sourcePaneID: sourcePaneID(drag),
            sharedTabID: sharedTabLayout?.snapshot.ids[drag.tab] ?? incomingSharedTabID(drag), group: drag.group
        )
    }
}

extension EnvironmentValues {
    @Entry var workbenchTabContext: WorkbenchTabContext?
}

private struct WorkbenchDragModifier<Preview: View>: ViewModifier {
    let payload: TabDragPayload
    let label: String?
    let preview: Preview
    var group: [TabDragPayload]? = nil
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        if
            let group, let context, context.hostID != nil,
            group.allSatisfy({ context.sharedTabLayout?.snapshot.ids[$0] != nil }),
            context.sharedTabLayout?.snapshot.layout.supportsGroupReordering != true {
            content
        } else if group == nil, let context, let detach = context.detach, payload.canDetach {
            content.background(WindowTabDragSource(tab: payload, label: label ?? "Tab") { point in
                detach(context.drag(payload), point)
            })
        } else {
            content.onDrag {
                var drag = context?.drag(payload)
                drag?.group = group
                let type: UTType = drag == nil ? .ctrlxTabDrag : .ctrlxWorkbenchTab
                WorkbenchTabDrag.active = (payload, drag)
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { complete in
                    do {
                        let encoder = JSONEncoder()
                        let data = try drag.map(encoder.encode) ?? encoder.encode(payload)
                        complete(data, nil)
                    } catch { complete(nil, error) }
                    return nil
                }
                return provider
            } preview: { preview }
        }
    }
}

private struct WorkbenchDropModifier: ViewModifier, DropDelegate {
    let placement: (CGPoint) -> WorkbenchTabDropPlacement
    let rightSide: Bool
    let action: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    let onHover: (WorkbenchTabHover?) -> Void
    var groupAction: (([TabDragPayload], WorkbenchTabDropPlacement) -> Bool)? = nil
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        content.onDrop(of: [contentType], delegate: self)
            .onDisappear { onHover(nil) }
    }

    private var contentType: UTType {
        context == nil ? .ctrlxTabDrag : .ctrlxWorkbenchTab
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(hover(at: placement(info.location)))
        // Keep rejected drops consumable so they cannot accidentally detach a tab.
        return DropProposal(operation: .copy)
    }

    private func hover(at placement: WorkbenchTabDropPlacement) -> WorkbenchTabHover? {
        guard let active = WorkbenchTabDrag.active else { return nil }
        if let context, let drag = active.context {
            return context.hover(drag, at: placement)
        }
        guard context == nil, active.context == nil, placement.accepts(active.tab) else { return nil }
        return WorkbenchTabHover(tab: active.tab, placement: placement, sourcePaneID: nil)
    }

    func dropExited(info: DropInfo) {
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            onHover(nil)
            WorkbenchTabDrag.active = nil
        }
        let providers = info.itemProviders(for: [contentType])
        guard providers.count == 1, let provider = providers.first else { return false }
        let destination = placement(info.location)
        provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in apply(data, to: destination) }
        }
        return true
    }

    private func apply(_ data: Data, to destination: WorkbenchTabDropPlacement) {
        if let context, let drag = try? JSONDecoder().decode(WorkbenchTabDrag.self, from: data) {
            _ = context.drop(drag, at: destination, rightSide: rightSide) { placement in
                if let group = drag.group {
                    return groupAction?(group, placement) ?? false
                }
                return action([drag.tab], placement)
            }
        } else if context == nil, let tab = try? JSONDecoder().decode(TabDragPayload.self, from: data), destination.accepts(tab) {
            _ = action([tab], destination)
        }
    }
}

struct WorkbenchTabDropNotice: ViewModifier {
    @Binding var presentationID: UUID?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if presentationID != nil {
                    Text("Only tabs from the same host and session can be combined.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("workbench-tab-drop-notice")
                }
            }
            .task(id: presentationID) {
                guard let id = presentationID else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, presentationID == id else { return }
                presentationID = nil
            }
    }
}

extension View {
    func workbenchGroupDraggable(_ first: TabDragPayload, members: [TabDragPayload], label: String) -> some View {
        modifier(WorkbenchDragModifier(payload: first, label: label, preview: Text(label), group: members))
    }

    func workbenchDraggable(_ payload: TabDragPayload, label: String? = nil, @ViewBuilder preview: () -> some View) -> some View {
        modifier(WorkbenchDragModifier(payload: payload, label: label, preview: preview()))
    }

    func workbenchDropDestination(
        rightSide: Bool = false,
        placement: @escaping (CGPoint) -> WorkbenchTabDropPlacement,
        action: @escaping ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool,
        groupAction: (([TabDragPayload], WorkbenchTabDropPlacement) -> Bool)? = nil,
        onHover: @escaping (WorkbenchTabHover?) -> Void
    ) -> some View {
        modifier(WorkbenchDropModifier(placement: placement, rightSide: rightSide, action: action, onHover: onHover, groupAction: groupAction))
    }
}

@MainActor
struct SharedWorkbenchTabLayout {
    struct Snapshot: Equatable {
        let ids: [TabDragPayload: SessionTabID]
        let layout: SessionTabLayout
        var sourcePanes: [SessionTabID: String] = [:]
        var paneOrder: [String] = []

        var groups: [TabDragPayload: UUID] {
            ids.compactMapValues { layout.groups[$0] }
        }

        func order(_ fallback: [TabDragPayload], localGroups: [TabDragPayload: UUID] = [:], sourcePane: (TabDragPayload) -> String? = { _ in nil }) -> [TabDragPayload] {
            guard layout.revision > 0 else { return fallback }
            let catalog = fallback.compactMap { ids[$0] }
            let byID = Dictionary(fallback.compactMap { tab in ids[tab].map { ($0, tab) } }, uniquingKeysWith: { first, _ in first })
            if layout.ordersGroups == true || !localGroups.isEmpty {
                let entries = SessionTabEntry.grouped(fallback, preserveGroupPositions: true) { tab in
                    (localGroups[tab] ?? groups[tab]).map(SessionTabGroup.manual) ?? sourcePane(tab).map(SessionTabGroup.pane)
                }
                let localRows = Set(entries.filter { entry in
                    entry.tabs.contains { localGroups[$0] != nil } && entry.tabs.contains { ids[$0] == nil }
                }.map(\.id))
                let owners = Dictionary(uniqueKeysWithValues: entries.flatMap { entry in entry.tabs.map { ($0, entry.id) } })
                let rows = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
                let sharedOrder = layout.ordered(catalog).compactMap { byID[$0] }
                var seen: Set<SessionTabEntry<TabDragPayload>.ID> = []
                var orderedRows = sharedOrder.compactMap { owners[$0] }.filter { !localRows.contains($0) && seen.insert($0).inserted }.compactMap { rows[$0] }
                if layout.ordersGroups != true {
                    orderedRows = orderedRows.filter { $0.sourcePaneID == nil }
                        + entries.filter { $0.sourcePaneID != nil && seen.contains($0.id) }
                }
                var ordered = orderedRows.makeIterator()
                return entries.flatMap { entry in
                    if localRows.contains(entry.id) {
                        return entry.tabs
                    }
                    let row = entry.tabs.contains(where: { ids[$0] != nil }) ? ordered.next() ?? entry : entry
                    let members = Set(row.tabs)
                    var sharedMembers = sharedOrder.filter(members.contains).makeIterator()
                    return row.tabs.map { ids[$0] == nil ? $0 : sharedMembers.next() ?? $0 }
                }
            }
            // Fill shared slots within each level so private tabs keep their local positions.
            var shared = Dictionary(grouping: layout.ordered(catalog).compactMap { byID[$0] }, by: sourcePane)
                .mapValues { $0.makeIterator() }
            return fallback.map { ids[$0] == nil ? $0 : shared[sourcePane($0)]?.next() ?? $0 }
        }
    }

    let snapshot: Snapshot
    let send: (SessionTabLayout.Edit, [SessionTabID]?, [SessionTabID]?, [TabDragPayload], @escaping @MainActor () -> Void) -> Void

    func moveGroup(
        _ members: [TabDragPayload], order: [TabDragPayload], initialOrder: [TabDragPayload],
        localGroups: [TabDragPayload: UUID] = [:], sourcePaneID: String? = nil, before targets: [TabDragPayload] = [],
        onSuccess: @escaping @MainActor () -> Void
    ) -> Bool {
        var ids = members.compactMap { snapshot.ids[$0] }
        let visibleMembers = Set(ids)
        let moving = Set(members)
        guard
            !members.contains(where: { localGroups[$0] != nil }),
            snapshot.layout.supportsGroupReordering == true, !ids.isEmpty,
            moving.isSubset(of: Set(order)) else { return false }
        let group = ids.lazy.compactMap { snapshot.layout.groups[$0] }.first
        if let group {
            ids = snapshot.layout.order.filter { snapshot.layout.groups[$0] == group }
        } else if let sourcePaneID, !snapshot.sourcePanes.isEmpty {
            ids = snapshot.layout.order.filter { snapshot.sourcePanes[$0] == sourcePaneID && snapshot.layout.groups[$0] == nil }
        }
        let sharedOrder = order.compactMap { snapshot.ids[$0] }
        let initial = initialOrder.compactMap { snapshot.ids[$0] }
        let sharedInitial = initialOrder.filter { localGroups[$0] == nil }.compactMap { snapshot.ids[$0] }
        let complete = snapshot.layout.reconciled(with: snapshot.layout.order + initial).initializingGroupOrder(from: sharedInitial, windowOrder: snapshot.layout.order.filter {
            if case .window = $0 {
                true
            } else {
                false
            }
        }, moving: ids, sourcePanes: snapshot.sourcePanes, paneOrder: snapshot.paneOrder)
        let entries = SessionTabEntry.grouped(complete.order, preserveGroupPositions: true) { tab in
            complete.groups[tab].map(SessionTabGroup.manual) ?? snapshot.sourcePanes[tab].map(SessionTabGroup.pane)
        }
        let owners = Dictionary(uniqueKeysWithValues: entries.flatMap { row in row.tabs.map { ($0, row.id) } })
        let visible = Set(initial)
        var replacements = sharedOrder.makeIterator()
        let projected = complete.order.map { visible.contains($0) ? replacements.next() ?? $0 : $0 }
        let sharedMembers = Set(ids)
        guard
            let source = projected.lastIndex(where: visibleMembers.contains),
            let visibleSource = sharedOrder.lastIndex(where: visibleMembers.contains) else { return false }
        let precedingRows = Set(sharedOrder[..<visibleSource].compactMap { owners[$0] })
            .subtracting(sharedOrder.dropFirst(visibleSource + 1).compactMap { owners[$0] })
        // Hidden continuations of a group already placed before us are not a new target.
        let next = targets.compactMap { snapshot.ids[$0] }.first { !sharedMembers.contains($0) } ?? projected.dropFirst(source + 1).first { tab in
            !sharedMembers.contains(tab) && owners[tab].map { !precedingRows.contains($0) } != false
        }
        let windows = ids.contains {
            if case .window = $0 {
                true
            } else {
                false
            }
        }
            ? (sharedOrder + ids.filter { !visible.contains($0) }).filter {
                if case .window = $0 {
                    true
                } else {
                    false
                }
            } : nil
        send(.moveGroup(ids, before: next, groupID: group, sourcePaneID: group == nil ? sourcePaneID : nil), snapshot.layout.ordersGroups != true ? sharedInitial : nil, windows, [], onSuccess)
        return true
    }

    func drop(
        _ source: TabDragPayload, at placement: WorkbenchTabDropPlacement, order: [TabDragPayload],
        onSuccess: @escaping @MainActor () -> Void = { }
    ) -> Bool {
        guard let sourceID = snapshot.ids[source] else { return false }
        let sharedOrder = order.compactMap { snapshot.ids[$0] }
        let edit: SessionTabLayout.Edit
        var affected = [source]
        var proposed = placement.placing(source, in: order).compactMap { snapshot.ids[$0] }
        switch placement {
        case let .before(_, members),
             let .after(_, members):
            guard placement.accepts(source) else { return false }
            if members != nil {
                affected = []
            }
            guard let move = edgeMove(sourceID, at: placement, from: sharedOrder, to: proposed) else {
                onSuccess()
                return true
            }
            edit = move
        case let .group(targets):
            let targetIDs = targets.compactMap { snapshot.ids[$0] }
            guard !targets.contains(source), !targets.isEmpty, targets.count == targetIDs.count else { return false }
            edit = .group(sourceID, with: targetIDs)
            affected = targets + [source]
        case let .end(tabs):
            let anchor = tabs.last { $0 != source && order.contains($0) }
            if let anchor, let id = snapshot.ids[anchor] {
                edit = .moveToEnd(sourceID, after: id)
            } else {
                var previous = order.contains(source) || snapshot.layout.revision == 0
                    ? sharedOrder : snapshot.layout.ordered(proposed)
                if anchor == nil || proposed.count < 2 || previous == proposed {
                    // Preserve the Host rank when the drop only changes local positions or group membership.
                    previous = snapshot.layout.order
                    proposed = previous
                }
                guard let relative = relativeMove(sourceID, from: previous, to: proposed, groupMembership: .leave) else {
                    onSuccess()
                    return true
                }
                edit = relative
            }
        }
        let windows: [SessionTabID]? = if case .window = sourceID {
            proposed.filter {
                if case .window = $0 {
                    true
                } else {
                    false
                }
            }
        } else {
            nil
        }
        send(edit, snapshot.layout.revision == 0 ? sharedOrder : nil, windows, affected, onSuccess)
        return true
    }

    func leavesGroupOnDrop(
        _ source: TabDragPayload, at placement: WorkbenchTabDropPlacement, order: [TabDragPayload], incomingID: SessionTabID? = nil
    ) -> Bool {
        guard let sourceID = incomingID ?? snapshot.ids[source] else { return false }
        switch placement {
        case .before(_, nil),
             .after(_, nil):
            return edgeMove(
                sourceID, at: placement, from: order.compactMap { snapshot.ids[$0] },
                to: placement.placing(source, in: order).compactMap { $0 == source ? sourceID : snapshot.ids[$0] }
            ) != nil
        case .end:
            return snapshot.layout.groups[sourceID] != nil
        case .before,
             .after,
             .group: return false
        }
    }

    private func edgeMove(
        _ source: SessionTabID, at placement: WorkbenchTabDropPlacement, from previous: [SessionTabID], to next: [SessionTabID]
    ) -> SessionTabLayout.Edit? {
        switch placement {
        case let .before(target, members),
             let .after(target, members):
            let membership: SessionTabLayout.GroupMembership = members == nil ? .leave : .keep
            if let targetID = snapshot.ids[target] {
                if case .after = placement {
                    return .moveToEnd(source, after: targetID, groupMembership: membership)
                }
                return .move(source, before: targetID, groupMembership: membership)
            }
            return relativeMove(source, from: previous, to: next, groupMembership: membership)
        case .group,
             .end: return nil
        }
    }

    private func relativeMove(
        _ source: SessionTabID, from previous: [SessionTabID], to next: [SessionTabID],
        groupMembership: SessionTabLayout.GroupMembership
    ) -> SessionTabLayout.Edit? {
        guard next != previous || (groupMembership == .leave && snapshot.layout.groups[source] != nil) else { return nil }
        if let index = next.firstIndex(of: source), index > 0 {
            return .moveToEnd(source, after: next[index - 1], groupMembership: groupMembership)
        }
        if next.count > 1 {
            return .move(source, before: next[1], groupMembership: groupMembership)
        }
        return .moveToEnd(source, after: nil, groupMembership: groupMembership)
    }

    func ungroup(_ tab: TabDragPayload) {
        guard let id = snapshot.ids[tab] else { return }
        send(.ungroup(id), nil, nil, [tab]) { }
    }
}
