import CtrlxCommon
import SwiftUI

@MainActor
struct SessionReorderableRows<Session: Identifiable, Row: View>: View {
    let sessions: [Session]
    let sessionName: KeyPath<Session, String>
    let selection: (Session) -> SidebarSessionSelection
    let onMove: (String, SessionDropTarget) -> Void
    let rowBackground: (Session) -> Color?
    @ViewBuilder let row: (Session) -> Row

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragSource: String?
    @State private var dropTarget: SessionDropTarget?

    private var sessionNames: [String] { sessions.map { $0[keyPath: sessionName] } }

    var body: some View {
        ForEach(sessions) { session in
            let name = session[keyPath: sessionName]
            HStack(spacing: 4) {
                row(session)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(dragSource == name ? 0.6 : 1)
                dragHandle(for: name)
            }
            .background(rowBackground(session) ?? .clear, in: .rect(cornerRadius: 5))
            .background(SidebarSelectionBackground().accessibilityHidden(true))
            .listRowBackground(Color.clear)
            .overlay(alignment: dropTarget?.insertAfter == true ? .bottom : .top) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .opacity(dropTarget?.sessionName == name ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                if rowFrames[name] != frame { rowFrames[name] = frame }
            }
            .onDisappear {
                rowFrames.removeValue(forKey: name)
                if dragSource == name { clearDrag() }
            }
            .tag(selection(session))
        }
    }

    private func dragHandle(for name: String) -> some View {
        SessionReorderHandle(
            isDragging: dragSource == name,
            onChanged: { location in
                if dragSource != name { dragSource = name }
                let target = target(for: name, at: location)
                if dropTarget != target { dropTarget = target }
            },
            onEnded: { location in
                defer { clearDrag() }
                guard let target = target(for: name, at: location) else { return }
                onMove(name, target)
            },
            onCancelled: clearDrag
        )
        .accessibilityElement()
        .accessibilityLabel("Reorder \(name)")
        .accessibilityHint("Drag within this session group")
        .accessibilityAction(named: "Move Up") { move(name, by: -1) }
        .accessibilityAction(named: "Move Down") { move(name, by: 1) }
        .help("Drag to reorder sessions")
    }

    private func target(for source: String, at location: CGPoint) -> SessionDropTarget? {
        SessionDropTarget.resolve(at: location, sessionNames: sessionNames, rowFrames: rowFrames, excluding: source)
    }

    private func move(_ name: String, by offset: Int) {
        let names = sessionNames
        guard let index = names.firstIndex(of: name), names.indices.contains(index + offset) else { return }
        onMove(name, SessionDropTarget(sessionName: names[index + offset], insertAfter: offset > 0))
    }

    private func clearDrag() {
        dragSource = nil
        dropTarget = nil
    }
}
