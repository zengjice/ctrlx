import AppKit
import SwiftUI

// Keep native List selection for navigation, but let the existing theme-aware
// row background be the only highlight (and obey the sidebar appearance setting).
@MainActor
struct SidebarSelectionBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarSelectionBackgroundView {
        SidebarSelectionBackgroundView()
    }

    func updateNSView(_ view: SidebarSelectionBackgroundView, context: Context) {
        view.suppressNativeHighlight()
    }
}

@MainActor
final class SidebarSelectionBackgroundView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        suppressNativeHighlight()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressNativeHighlight()
    }

    override func layout() {
        super.layout()
        suppressNativeHighlight()
    }

    func suppressNativeHighlight() {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                return
            }
            ancestor = view.superview
        }
    }
}
