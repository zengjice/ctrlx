import AppKit
import SwiftUI

/// Escape belongs to dictation only while recording in this native window.
/// This view never becomes a responder or creates a popup window.
@MainActor
struct MacVoiceInputCancellation: NSViewRepresentable {
    let isActive: Bool
    let onCancel: @MainActor () -> Void

    func makeNSView(context: Context) -> MacVoiceInputCancellationView {
        MacVoiceInputCancellationView()
    }

    func updateNSView(_ view: MacVoiceInputCancellationView, context: Context) {
        view.onCancel = onCancel
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MacVoiceInputCancellationView, coordinator: ()) {
        view.setActive(false)
    }
}

@MainActor
final class MacVoiceInputCancellationView: NSView {
    var onCancel: (@MainActor () -> Void)?
    private var isActive = false
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitoring()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        updateMonitoring()
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard
            isActive, window != nil, event.window === window,
            event.type == .keyDown, event.keyCode == 53,
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return event }
        cancel()
        return nil
    }

    private func updateMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        guard isActive, let window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        let notifications: [(Notification.Name, AnyObject?)] = [
            (NSApplication.didResignActiveNotification, nil),
            (NSWindow.didResignKeyNotification, window),
        ]
        for (name, object) in notifications {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
    }

    private func cancel() {
        guard isActive else { return }
        setActive(false)
        onCancel?()
    }
}
