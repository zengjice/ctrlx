import AppKit

/// CEF needs a real parent for background pages, but it must never reach the desktop.
@MainActor
final class AgentBrowserParkingWindow: NSWindow {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .out else { return }
        super.order(place, relativeTo: otherWin)
    }

    /// This entry point can order a window without going through order(_:relativeTo:).
    override func orderFrontRegardless() { }
}
