import CtrlxNetworking
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct IOSTabDropTarget: ViewModifier, DropDelegate {
    typealias HoverHandler = ((source: SessionTabID, action: IOSSessionTabDrop.Action)?) -> Void

    let drop: IOSSessionTabDrop
    let onHover: HoverHandler
    let apply: @MainActor @Sendable (IOSSessionTabDrop.Action) -> Void
    let onFailure: @MainActor @Sendable (IOSSessionTabDrop.Rejection) -> Void
    @State private var height: CGFloat = 0
    @State private var isGrouping = false

    func body(content: Content) -> some View {
        content
            .background {
                if isGrouping {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.15))
                        .padding(.horizontal, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isGrouping {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(.horizontal, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
            .onDrop(of: [IOSSessionTabDrag.contentType], delegate: self)
            .onDisappear { onHover(nil) }
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropUpdated(position: info.location.y, height: height)
    }

    func dropUpdated(position: CGFloat, height: CGFloat) -> DropProposal {
        let hover = IOSSessionTabDrag.active.flatMap { drag -> (source: SessionTabID, action: IOSSessionTabDrop.Action)? in
            guard case let .success(action?) = drop.plan(drag, position: position, height: height) else { return nil }
            return (source: drag.tab, action: action)
        }
        let grouping = hover?.action.groupsTabs == true
        if isGrouping != grouping {
            isGrouping = grouping
        }
        onHover(hover)
        // Hover is advisory. The provider identifies the source when the user drops.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isGrouping = false
        onHover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dropExited(info: info) }
        return performDrop(info.itemProviders(for: [IOSSessionTabDrag.contentType]), position: info.location.y, height: height)
    }

    func performDrop(_ providers: [NSItemProvider], position: CGFloat, height: CGFloat) -> Bool {
        drop.perform(providers, position: position, height: height) { result in
            switch result {
            case let .success(action?): apply(action)
            case .success(nil): break
            case let .failure(rejection): onFailure(rejection)
            }
        }
    }
}
