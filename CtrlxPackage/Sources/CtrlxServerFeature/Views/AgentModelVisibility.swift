import AppKit
import SwiftUI

/// A visible split keeps refreshing even when another split or window has keyboard focus.
struct AgentModelVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.visibilityChanged = {
            if isVisible != $0 {
                isVisible = $0
            }
        }
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.visibilityChanged = {
            if isVisible != $0 {
                isVisible = $0
            }
        }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.stop()
    }

    @MainActor
    final class Anchor: NSView {
        var visibilityChanged: ((Bool) -> Void)?
        private var update: Task<Void, Never>?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(reportVisibility), name: name, object: window)
                }
            }
            reportVisibility()
        }

        override func viewDidHide() {
            super.viewDidHide()
            reportVisibility()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            reportVisibility()
        }

        @objc
        private func reportVisibility() {
            update?.cancel()
            // AppKit can call this while SwiftUI is mounting or updating the strip.
            update = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                visibilityChanged?(window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor)
            }
        }

        func stop() {
            NotificationCenter.default.removeObserver(self)
            update?.cancel()
            update = nil
            visibilityChanged = nil
        }
    }
}
