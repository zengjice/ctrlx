import AppKit
import SwiftUI

/// Delay speech until a stationary press is deliberate. Short presses and
/// selection drags can replay their original mouse-down through the terminal.
@MainActor
final class MacVoiceInputPress {
    private var down: NSEvent?
    private var task: Task<Void, Never>?
    private var holding = false
    private var finish: ((Bool) -> Void)?

    var isActive: Bool {
        down != nil
    }

    func mouseDown(_ event: NSEvent, begin: @escaping () -> Bool, finish: @escaping (Bool) -> Void) {
        cancel()
        down = event
        self.finish = finish
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, down != nil else { return }
            holding = begin()
        }
    }

    /// A movement before recording begins belongs to text selection.
    func mouseDragged(_ event: NSEvent) -> NSEvent? {
        guard let down, !holding else { return nil }
        let distance = hypot(
            event.locationInWindow.x - down.locationInWindow.x,
            event.locationInWindow.y - down.locationInWindow.y
        )
        guard distance > 5 else { return nil }
        cancel()
        return down
    }

    /// Nil means the hold consumed the click; otherwise replay the short click.
    func mouseUp() -> NSEvent? {
        let original = holding ? nil : down
        end(cancelled: false)
        return original
    }

    func cancel() {
        end(cancelled: true)
    }

    private func end(cancelled: Bool) {
        task?.cancel()
        task = nil
        let completion = holding ? finish : nil
        down = nil
        holding = false
        finish = nil
        completion?(cancelled)
    }
}

/// Pointer handling only; the SwiftUI Button retains keyboard/VoiceOver actions.
@MainActor
struct MacVoiceInputPressTarget: NSViewRepresentable {
    let onTap: () -> Void
    let onBegin: () -> Bool
    let onEnd: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> Target {
        Target()
    }

    func updateNSView(_ view: Target, context: Context) {
        view.isEnabled = isEnabled
        view.onTap = onTap
        view.onBegin = onBegin
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: Target, coordinator: Void) {
        view.stop()
    }

    final class Target: NSView {
        let press = MacVoiceInputPress()
        var isEnabled = true
        var onTap: (() -> Void)?
        var onBegin: (() -> Bool)?
        var onEnd: ((Bool) -> Void)?
        private var monitor: Any?
        private var tracking = false
        private var tap: (() -> Void)?

        override var acceptsFirstResponder: Bool {
            false
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseDown {
                guard
                    isEnabled, !isHiddenOrHasHiddenAncestor, event.window === window,
                    bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                tracking = true
                tap = onTap
                begin(event)
            } else {
                guard tracking else { return event }
                if event.type == .leftMouseDragged {
                    _ = press.mouseDragged(event)
                } else {
                    tracking = false
                    defer { tap = nil }
                    if
                        press.mouseUp() != nil, isEnabled, event.window === window,
                        bounds.contains(convert(event.locationInWindow, from: nil)) {
                        tap?()
                    }
                }
            }
            return nil
        }

        private func begin(_ event: NSEvent) {
            let begin = onBegin
            let end = onEnd
            press.mouseDown(event, begin: { [weak self] in
                guard self?.window?.isKeyWindow == true, self?.isEnabled == true else { return false }
                return begin?() == true
            }, finish: { end?($0) })
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            tracking = false
            tap = nil
            press.cancel()
        }
    }
}
