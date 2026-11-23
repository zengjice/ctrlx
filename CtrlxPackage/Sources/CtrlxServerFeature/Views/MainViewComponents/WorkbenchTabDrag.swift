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
}

struct WorkbenchTabHover: Equatable {
    let tab: TabDragPayload
    let placement: WorkbenchTabDropPlacement
    let sourcePaneID: String?
    var sharedTabID: SessionTabID? = nil
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
            sharedTabID: sharedTabLayout?.snapshot.ids[drag.tab] ?? incomingSharedTabID(drag)
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
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        if let context, let detach = context.detach, payload.canDetach {
            content.background(WindowTabDragSource(tab: payload, label: label ?? "Tab") { point in
                detach(context.drag(payload), point)
            })
        } else {
            content.onDrag {
                let drag = context?.drag(payload)
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
                action([drag.tab], placement)
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
    func workbenchDraggable(_ payload: TabDragPayload, label: String? = nil, @ViewBuilder preview: () -> some View) -> some View {
        modifier(WorkbenchDragModifier(payload: payload, label: label, preview: preview()))
    }

    func workbenchDropDestination(
        rightSide: Bool = false,
        placement: @escaping (CGPoint) -> WorkbenchTabDropPlacement,
        action: @escaping ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool,
        onHover: @escaping (WorkbenchTabHover?) -> Void
    ) -> some View {
        modifier(WorkbenchDropModifier(placement: placement, rightSide: rightSide, action: action, onHover: onHover))
    }
}

@MainActor
struct SharedWorkbenchTabLayout {
    struct Snapshot: Equatable {
        let ids: [TabDragPayload: SessionTabID]
        let layout: SessionTabLayout

        var groups: [TabDragPayload: UUID] {
            ids.compactMapValues { layout.groups[$0] }
        }

        func order(_ fallback: [TabDragPayload], sourcePane: (TabDragPayload) -> String? = { _ in nil }) -> [TabDragPayload] {
            guard layout.revision > 0 else { return fallback }
            let catalog = fallback.compactMap { ids[$0] }
            let byID = Dictionary(fallback.compactMap { tab in ids[tab].map { ($0, tab) } }, uniquingKeysWith: { first, _ in first })
            // Fill shared slots within each level so private tabs keep their local positions.
            var shared = Dictionary(grouping: layout.ordered(catalog).compactMap { byID[$0] }, by: sourcePane)
                .mapValues { $0.makeIterator() }
            return fallback.map { ids[$0] == nil ? $0 : shared[sourcePane($0)]?.next() ?? $0 }
        }
    }

    let snapshot: Snapshot
    let send: (SessionTabLayout.Edit, [SessionTabID]?, [SessionTabID]?, [TabDragPayload], @escaping @MainActor () -> Void) -> Void

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
