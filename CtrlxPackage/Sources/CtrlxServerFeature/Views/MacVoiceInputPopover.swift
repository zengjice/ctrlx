import AppKit
import SwiftUI

/// A transient SwiftUI popover consumes the microphone click as dismissal.
/// Own dismissal instead so the same button can finish an active recording.
@MainActor
struct MacVoiceInputPopover<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let onCancel: @MainActor () -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> MacVoiceInputPopoverAnchor {
        MacVoiceInputPopoverAnchor()
    }

    func updateNSView(_ view: MacVoiceInputPopoverAnchor, context: Context) {
        view.onCancel = onCancel
        if isPresented {
            view.show(content: content)
        } else {
            view.close()
        }
    }

    static func dismantleNSView(_ view: MacVoiceInputPopoverAnchor, coordinator: ()) {
        view.close()
    }
}

@MainActor
final class MacVoiceInputPopoverAnchor: NSView, NSPopoverDelegate {
    let popover = NSPopover()
    var onCancel: (@MainActor () -> Void)?
    private var eventMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show<Content: View>(content: Content) {
        if let controller = popover.contentViewController as? NSHostingController<Content> {
            controller.rootView = content
        } else {
            let controller = NSHostingController(rootView: content)
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
        }
        guard !popover.isShown, window != nil else { return }
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        guard popover.isShown else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown else { return event }
        if event.type == .keyDown {
            if event.keyCode == 53, event.window === window || event.window === popover.contentViewController?.view.window {
                cancel()
                return nil
            }
            return event
        }
        if event.window === popover.contentViewController?.view.window { return event }
        if
            event.type == .leftMouseDown, event.window === window,
            bounds.contains(convert(event.locationInWindow, from: nil)) {
            return event
        }
        cancel()
        return event
    }

    func close() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        // Programmatic completion/teardown is not a user cancellation.
        popover.delegate = nil
        // Finish closing before a new recording can reuse this popover.
        let animated = popover.animates
        popover.animates = false
        popover.close()
        popover.animates = animated
        popover.delegate = self
    }

    func popoverDidClose(_ notification: Notification) {
        cancel()
    }

    private func cancel() {
        guard eventMonitor != nil else { return }
        close()
        onCancel?()
    }
}
