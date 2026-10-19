import AppKit
import SwiftUI

/// Semitransient presentation lets a single click switch accounts in the same
/// toolbar. SwiftUI's transient popover consumes that click while dismissing.
struct DashboardQuotaPopover<Content: View>: NSViewRepresentable {
    @Binding var width: CGFloat
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> Anchor {
        Anchor()
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.widthChanged = { width = $0 }
        view.dismissed = { isPresented = false }
        view.update(
            content: AnyView(content().environment(\.colorScheme, context.environment.colorScheme)),
            presented: isPresented
        )
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        view.stop()
    }

    final class Anchor: NSView, NSPopoverDelegate {
        var widthChanged: ((CGFloat) -> Void)?
        var dismissed: (() -> Void)?
        private var observation: Task<Void, Never>?
        private var monitor: Any?
        private let popover = NSPopover()
        private let host = NSHostingController(rootView: AnyView(EmptyView()))

        override init(frame: NSRect) {
            super.init(frame: frame)
            popover.behavior = .semitransient
            popover.animates = false
            popover.contentViewController = host
            popover.delegate = self
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation?.cancel()
            guard window != nil else { stop()
                return
            }
            observation = Task { @MainActor [weak self] in
                self?.widthChanged?(self?.window?.frame.width ?? 0)
                // Do not retain the owning window across the suspension point.
                for await notification in NotificationCenter.default.notifications(named: NSWindow.didResizeNotification) {
                    guard !Task.isCancelled, let self else { return }
                    if let window = self.window, notification.object as? NSWindow === window {
                        self.widthChanged?(window.frame.width)
                    }
                }
            }
        }

        func update(content: AnyView, presented: Bool) {
            guard presented else { popover.close()
                return
            }
            host.rootView = content
            guard !popover.isShown, window != nil else { return }
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, self.popover.isShown else { return false }
                    if event.type == .keyDown {
                        if event.keyCode == 53 {
                            self.popover.close()
                            return true
                        }
                    } else if event.window === self.window, !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                        self.popover.close()
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }

        func popoverDidClose(_ notification: Notification) {
            removeMonitor()
            // Delegate callbacks may occur during a SwiftUI update.
            Task { @MainActor [weak self] in
                guard let self, !popover.isShown else { return }
                dismissed?()
            }
        }

        func stop() {
            observation?.cancel()
            observation = nil
            dismissed = nil
            popover.close()
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
