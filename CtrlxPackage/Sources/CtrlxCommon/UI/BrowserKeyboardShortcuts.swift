#if os(macOS)
    import AppKit
    import SwiftUI

    public enum BrowserKeyboardShortcut: Equatable, Sendable {
        case reload
        case focusAddress
        case back
        case forward

        static func matching(_ event: NSEvent) -> Self? {
            guard
                event.type == .keyDown,
                event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return nil }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": return .reload
            case "l": return .focusAddress
            case "[": return .back
            case "]": return .forward
            default: return nil
            }
        }
    }

    private struct BrowserKeyboardActiveKey: EnvironmentKey {
        static let defaultValue = true
    }

    public extension EnvironmentValues {
        var browserKeyboardActive: Bool {
            get { self[BrowserKeyboardActiveKey.self] }
            set { self[BrowserKeyboardActiveKey.self] = newValue }
        }
    }

    public extension View {
        func browserKeyboardShortcuts(isEnabled: Bool, perform: @escaping @MainActor (BrowserKeyboardShortcut) -> Void) -> some View {
            modifier(BrowserKeyboardShortcuts(isEnabled: isEnabled, perform: perform))
        }
    }

    private struct BrowserKeyboardShortcuts: ViewModifier {
        let isEnabled: Bool
        let perform: @MainActor (BrowserKeyboardShortcut) -> Void
        @Environment(\.browserKeyboardActive) private var isActive

        func body(content: Content) -> some View {
            content.background(BrowserKeyboardAnchor(isActive: isActive, isEnabled: isEnabled, perform: perform))
        }
    }

    private struct BrowserKeyboardAnchor: NSViewRepresentable {
        let isActive: Bool
        let isEnabled: Bool
        let perform: @MainActor (BrowserKeyboardShortcut) -> Void

        func makeNSView(context: Context) -> BrowserKeyboardShortcutView {
            BrowserKeyboardShortcutView()
        }

        func updateNSView(_ view: BrowserKeyboardShortcutView, context: Context) {
            view.isActive = isActive
            view.isEnabled = isEnabled
            view.perform = perform
        }

        static func dismantleNSView(_ view: BrowserKeyboardShortcutView, coordinator: ()) {
            view.stop()
        }
    }

    /// Intercept before the native page or the global Refresh Sessions menu.
    /// The workbench supplies the focused split; no first-responder changes are needed.
    @MainActor
    final class BrowserKeyboardShortcutView: NSView {
        var isActive = true
        var isEnabled = true
        var perform: @MainActor (BrowserKeyboardShortcut) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return handle(event)
            }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard
                let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
                !isHiddenOrHasHiddenAncestor, isActive,
                let shortcut = BrowserKeyboardShortcut.matching(event) else { return event }
            if isEnabled {
                perform(shortcut)
                if shortcut == .focusAddress, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.selectAll(nil)
                }
            }
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
