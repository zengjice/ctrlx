import CtrlxCommon
import CtrlxNetworking
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var ctrlxWorkbenchTab: UTType {
        UTType(exportedAs: "com.jicezeng.ctrlx.workbench-tab")
    }
}

struct WorkbenchTabDrag: Codable, Transferable {
    let workspaceID: UUID?
    let hostID: String?
    let sessionName: String
    let tab: TabDragPayload

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ctrlxWorkbenchTab)
    }
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
    case group([TabDragPayload])
    case end([TabDragPayload])

    var targets: [TabDragPayload] {
        switch self {
        case let .before(target, _): [target]
        case let .group(targets),
             let .end(targets): targets
        }
    }

    func placing(_ source: TabDragPayload, in order: [TabDragPayload]) -> [TabDragPayload] {
        var result = order.filter { $0 != source }
        let index: Int? = switch self {
        case let .before(target, _): result.firstIndex(of: target)
        case let .group(targets): result.lastIndex(where: targets.contains).map { $0 + 1 }
        case let .end(targets):
            targets.reversed().lazy.compactMap { result.firstIndex(of: $0) }.first.map { $0 + 1 }
                ?? order.firstIndex(of: source)
        }
        result.insert(source, at: index ?? result.endIndex)
        return result
    }

    func accepts(_ source: TabDragPayload) -> Bool {
        if case let .before(target, members) = self {
            return source != target && (members?.contains(source) ?? true)
        }
        return true
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

    func drop(_ drag: WorkbenchTabDrag, at placement: WorkbenchTabDropPlacement, rightSide: Bool, reorder: (WorkbenchTabDropPlacement) -> Bool) -> Bool {
        guard accepts(drag) else {
            onRejected()
            // Consume the drop without moving a tab. An unhandled drop makes the
            // native terminal drag source fall back to creating a new window.
            return true
        }
        guard placement.accepts(drag.tab) else { return true }
        let group = sourcePaneGroup(drag)
        let destination: WorkbenchTabDropPlacement
        switch placement {
        case let .before(target, _):
            guard sourcePaneGroup(self.drag(target)) == group else { return true }
            destination = placement
        case .group:
            destination = placement
        case let .end(tabs):
            destination = .end(tabs.filter { sourcePaneGroup(self.drag($0)) == group })
        }
        if drag.workspaceID != workspaceID {
            return receive(drag, destination, rightSide)
        }
        return reorder(destination)
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
        } else if let context {
            content.draggable(context.drag(payload)) { preview }
        } else {
            content.draggable(payload) { preview }
        }
    }
}

private struct WorkbenchDropModifier: ViewModifier {
    let placement: (CGPoint) -> WorkbenchTabDropPlacement
    let rightSide: Bool
    let action: ([TabDragPayload], WorkbenchTabDropPlacement) -> Bool
    let targeted: (Bool) -> Void
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        if let context {
            content.dropDestination(for: WorkbenchTabDrag.self) { values, point in
                guard values.count == 1, let value = values.first else { return false }
                return context.drop(value, at: placement(point), rightSide: rightSide) { destination in
                    action([value.tab], destination)
                }
            } isTargeted: { targeted($0) }
        } else {
            content.dropDestination(for: TabDragPayload.self) { tabs, point in
                let destination = placement(point)
                guard tabs.allSatisfy(destination.accepts) else { return false }
                return action(tabs, destination)
            } isTargeted: { targeted($0) }
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
        isTargeted: @escaping (Bool) -> Void
    ) -> some View {
        modifier(WorkbenchDropModifier(placement: placement, rightSide: rightSide, action: action, targeted: isTargeted))
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
        case let .before(target, members):
            guard placement.accepts(source) else { return false }
            let groupMembership: SessionTabLayout.GroupMembership = members == nil ? .leave : .keep
            if members != nil {
                affected = []
            }
            if let targetID = snapshot.ids[target] {
                edit = .move(sourceID, before: targetID, groupMembership: groupMembership)
            } else {
                guard let relative = relativeMove(sourceID, from: sharedOrder, to: proposed, groupMembership: groupMembership) else {
                    onSuccess()
                    return true
                }
                edit = relative
            }
        case let .group(targets):
            let targetIDs = targets.compactMap { snapshot.ids[$0] }
            guard !targets.contains(source), !targets.isEmpty, targets.count == targetIDs.count else { return false }
            edit = .group(sourceID, with: targetIDs)
            affected = targets + [source]
        case let .end(tabs):
            if let anchor = tabs.reversed().lazy.filter({ $0 != source }).compactMap({ snapshot.ids[$0] }).first {
                edit = .moveToEnd(sourceID, after: anchor)
            } else {
                // An empty section or a private-only anchor can change local placement.
                // Keep the shared rank, including when leaving a manual group.
                proposed = snapshot.layout.order
                guard let relative = relativeMove(sourceID, from: proposed, to: proposed, groupMembership: .leave) else {
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
