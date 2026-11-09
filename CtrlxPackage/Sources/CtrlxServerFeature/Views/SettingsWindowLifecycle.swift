import AppKit
import SwiftUI

/// Settings scenes can retain their view after closing. Discard only this window's drafts.
struct SettingsWindowLifecycle: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.onClose = onClose
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    final class Anchor: NSView {
        var onClose: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: window)
            }
        }

        @objc
        private func closing() {
            onClose?()
        }
    }
}
