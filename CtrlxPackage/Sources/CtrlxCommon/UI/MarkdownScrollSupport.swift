#if os(macOS)
    import AppKit
    import SwiftUI

    /// Textual's horizontal code-block scrollers otherwise swallow vertical wheel events.
    @MainActor
    public struct MarkdownScrollSupport: NSViewRepresentable {
        public init() { }

        public func makeNSView(context: Context) -> NSView {
            MarkdownScrollSupportView()
        }

        public func updateNSView(_: NSView, context: Context) { }

        public static func dismantleNSView(_ view: NSView, coordinator: ()) {
            (view as? MarkdownScrollSupportView)?.stop()
        }
    }

    @MainActor
    final class MarkdownScrollSupportView: NSView {
        private var monitor: Any?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard
                event.type == .scrollWheel, let window, event.window === window,
                !isHiddenOrHasHiddenAncestor,
                event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                visibleRect.contains(convert(event.locationInWindow, from: nil)),
                let outer = enclosingScrollView, outer.hasVerticalScroller,
                let parent = outer.superview,
                let inner = outer.hitTest(parent.convert(event.locationInWindow, from: nil))?.enclosingScrollView,
                inner !== outer, inner.isDescendant(of: outer), !inner.hasVerticalScroller
            else { return event }

            outer.scrollWheel(with: event)
            return nil
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
#endif
