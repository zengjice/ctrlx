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

@MainActor
struct WorkbenchTabContext {
    let workspaceID: UUID?
    let hostID: String?
    let sessionName: String
    let receive: (WorkbenchTabDrag, TabDragPayload?, Bool) -> Bool

    func drag(_ tab: TabDragPayload) -> WorkbenchTabDrag {
        WorkbenchTabDrag(workspaceID: workspaceID, hostID: hostID, sessionName: sessionName, tab: tab)
    }

    func accepts(_ drag: WorkbenchTabDrag) -> Bool {
        drag.hostID == hostID && drag.sessionName == sessionName
    }
}

extension EnvironmentValues {
    @Entry var workbenchTabContext: WorkbenchTabContext?
}

private struct WorkbenchDragModifier<Preview: View>: ViewModifier {
    let payload: TabDragPayload
    let preview: Preview
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        if let context {
            content.draggable(context.drag(payload)) { preview }
        } else {
            content.draggable(payload) { preview }
        }
    }
}

private struct WorkbenchDropModifier: ViewModifier {
    let before: TabDragPayload?
    let rightSide: Bool
    let action: ([TabDragPayload], CGPoint) -> Bool
    let targeted: (Bool) -> Void
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        if let context {
            content.dropDestination(for: WorkbenchTabDrag.self) { values, point in
                guard values.count == 1, let value = values.first, context.accepts(value) else { return false }
                if value.workspaceID != context.workspaceID {
                    return context.receive(value, before, rightSide)
                }
                return action([value.tab], point)
            } isTargeted: { targeted($0) }
        } else {
            content.dropDestination(for: TabDragPayload.self, action: action, isTargeted: targeted)
        }
    }
}

extension View {
    func workbenchDraggable(_ payload: TabDragPayload, @ViewBuilder preview: () -> some View) -> some View {
        modifier(WorkbenchDragModifier(payload: payload, preview: preview()))
    }

    func workbenchDropDestination(
        before: TabDragPayload? = nil,
        rightSide: Bool = false,
        action: @escaping ([TabDragPayload], CGPoint) -> Bool,
        isTargeted: @escaping (Bool) -> Void,
    ) -> some View {
        modifier(WorkbenchDropModifier(before: before, rightSide: rightSide, action: action, targeted: isTargeted))
    }
}
