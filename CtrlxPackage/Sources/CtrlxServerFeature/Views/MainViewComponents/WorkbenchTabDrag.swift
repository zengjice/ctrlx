import CtrlxCommon
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

@MainActor
struct WorkbenchTabContext {
    let workspaceID: UUID?
    let hostID: String?
    let sessionName: String
    let onRejected: () -> Void
    var detach: ((WorkbenchTabDrag, CGPoint?) -> Void)? = nil
    var returnToMain: ((WorkbenchTabDrag) -> Void)? = nil
    let receive: (WorkbenchTabDrag, TabDragPayload?, Bool) -> Bool

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

    func drop(_ drag: WorkbenchTabDrag, before: TabDragPayload?, rightSide: Bool, reorder: () -> Bool) -> Bool {
        guard accepts(drag) else {
            onRejected()
            // Consume the drop without moving a tab. An unhandled drop makes the
            // native terminal drag source fall back to creating a new window.
            return true
        }
        if drag.workspaceID != workspaceID {
            return receive(drag, before, rightSide)
        }
        return reorder()
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
    let before: TabDragPayload?
    let rightSide: Bool
    let action: ([TabDragPayload], CGPoint) -> Bool
    let targeted: (Bool) -> Void
    @Environment(\.workbenchTabContext) private var context

    func body(content: Content) -> some View {
        if let context {
            content.dropDestination(for: WorkbenchTabDrag.self) { values, point in
                guard values.count == 1, let value = values.first else { return false }
                return context.drop(value, before: before, rightSide: rightSide) {
                    action([value.tab], point)
                }
            } isTargeted: { targeted($0) }
        } else {
            content.dropDestination(for: TabDragPayload.self, action: action, isTargeted: targeted)
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
        before: TabDragPayload? = nil,
        rightSide: Bool = false,
        action: @escaping ([TabDragPayload], CGPoint) -> Bool,
        isTargeted: @escaping (Bool) -> Void
    ) -> some View {
        modifier(WorkbenchDropModifier(before: before, rightSide: rightSide, action: action, targeted: isTargeted))
    }
}
