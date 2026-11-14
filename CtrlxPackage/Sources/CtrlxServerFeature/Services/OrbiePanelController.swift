import AppKit
import Dependencies
import Observation

/// Presentation lifetime only; Agent work and drafts belong to the existing services.
@MainActor
@Observable
final class OrbiePanelController {
    private(set) var isVisible = false
    private(set) var shortcutIssue: String?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var presentWindow: (() -> Void)?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var desiredVisible = false
    @ObservationIgnored private var registration: OrbieHotkeyRegistration?
    @ObservationIgnored private var registeredValue: String?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let enabled: () -> Bool
    @ObservationIgnored @Dependency(OrbieHotkeyClient.self) private var hotkeys

    init(settings: AppSettings, enabled: @escaping () -> Bool) {
        self.settings = settings
        self.enabled = enabled
    }

    func start(present: @escaping () -> Void) {
        presentWindow = present
        guard !active else { return }
        active = true
        observeShortcut()
    }

    func stop() {
        active = false
        registration?.cancel()
        registration = nil
        registeredValue = nil
        dismiss(restoreFocus: false)
    }

    func show() {
        if !desiredVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        }
        desiredVisible = true
        if let window {
            display(window)
        } else {
            presentWindow?()
        }
    }

    func toggle() {
        if desiredVisible {
            dismiss(restoreFocus: true)
        } else {
            show()
        }
    }

    func attach(_ window: NSWindow) {
        self.window = window
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.setAccessibilityIdentifier("orbie-panel")
        if desiredVisible {
            display(window)
        } else {
            window.orderOut(nil)
        }
    }

    func dismiss(restoreFocus: Bool) {
        let ownedFocus = window?.isKeyWindow == true || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let restoreTo = previousApp
        previousApp = nil
        desiredVisible = false
        isVisible = false
        window?.orderOut(nil)
        if restoreFocus, ownedFocus, let restoreTo, !restoreTo.isTerminated {
            restoreTo.activate()
        }
    }

    func resignedKey() {
        if desiredVisible, window?.attachedSheet == nil {
            dismiss(restoreFocus: false)
        }
    }

    func becameKey() {
        if !desiredVisible {
            window?.orderOut(nil)
        }
    }

    static func frame(size: NSSize, visibleFrame: NSRect) -> NSRect {
        let width = min(size.width, visibleFrame.width - 32), height = min(size.height, visibleFrame.height - 32)
        return .init(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2, width: width, height: height)
    }

    private func display(_ window: NSWindow) {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            window.setFrame(Self.frame(size: window.frame.size, visibleFrame: screen.visibleFrame), display: true)
        }
        isVisible = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func observeShortcut() {
        guard active else { return }
        let state = withObservationTracking { (settings.orbieShortcutRaw, enabled()) } onChange: { [weak self] in
            Task { @MainActor in self?.observeShortcut() }
        }
        let value = state.1 ? state.0 : nil
        guard value != registeredValue || (value != nil && registration == nil && shortcutIssue == nil) else { return }
        registration?.cancel()
        registration = nil
        registeredValue = value
        shortcutIssue = nil
        guard let value else { return }
        guard let shortcut = OrbieShortcut(rawValue: value) else { shortcutIssue = "Choose a valid Orbie global shortcut in General settings."
            return
        }
        do {
            registration = try hotkeys.register(shortcut) { [weak self] in
                guard let self, active, enabled(), registeredValue == shortcut.rawValue else { return }
                toggle()
            }
        } catch { shortcutIssue = error.localizedDescription }
    }
}
