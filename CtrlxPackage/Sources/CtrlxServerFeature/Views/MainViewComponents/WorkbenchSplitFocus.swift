import AppKit
import SwiftUI

/// Observe clicks without consuming them, including native terminal and browser views.
struct WorkbenchSplitFocus: NSViewRepresentable {
    let tabs: SessionFileTabsState
    var onInteraction: () -> Void = { }

    func makeNSView(context: Context) -> WorkbenchSplitFocusView {
        WorkbenchSplitFocusView()
    }

    func updateNSView(_ view: WorkbenchSplitFocusView, context: Context) {
        view.tabs = tabs
        view.onInteraction = onInteraction
    }

    static func dismantleNSView(_ view: WorkbenchSplitFocusView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class WorkbenchSplitFocusView: NSView {
    weak var tabs: SessionFileTabsState?
    var onInteraction: () -> Void = { }
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    func record(_ event: NSEvent) {
        guard let tabs, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onInteraction()
        tabs.isRightPaneFocused = tabs.isSplit && point.x > bounds.width * tabs.splitRatio
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
