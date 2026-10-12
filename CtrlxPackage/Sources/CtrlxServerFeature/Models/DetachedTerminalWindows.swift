import AppKit
import CtrlxCommon
import Observation

/// Presentation identity, independent of session names and tmux window indices.
public struct DetachedTerminalTarget: Hashable, Codable, Sendable {
    let hostID: String?
    let windowID: String

    init?(hostID: String?, windowID: String) {
        // An old Host without stable window IDs cannot safely support detachment.
        guard windowID.first == "@", Int(windowID.dropFirst()) != nil else { return nil }
        self.hostID = hostID
        self.windowID = windowID
    }
}

@MainActor
@Observable
final class DetachedTerminalWindows {
    enum Action: Equatable {
        case show
        case files(paneID: String?)
        case fork(paneID: String?, worktree: Bool)
        case fileLink(TerminalFileLinkRequest)
        case url(String)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let target: DetachedTerminalTarget
        let action: Action
    }

    private(set) var targets: Set<DetachedTerminalTarget> = []
    var mainRequest: Request?
    @ObservationIgnored private var windows: [DetachedTerminalTarget: NSWindow] = [:]
    @ObservationIgnored private var positions: [DetachedTerminalTarget: CGPoint] = [:]
    @ObservationIgnored private var closeObservers: [DetachedTerminalTarget: NSObjectProtocol] = [:]

    isolated deinit {
        for observer in closeObservers.values {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func contains(hostID: String?, windowID: String) -> Bool {
        guard let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID) else { return false }
        return targets.contains(target)
    }

    /// Reserve ownership before SwiftUI creates the scene, so the main renderer retires first.
    @discardableResult
    func reserve(_ target: DetachedTerminalTarget, position: CGPoint? = nil) -> Bool {
        guard targets.insert(target).inserted else { return false }
        positions[target] = position
        return true
    }

    func attach(_ window: NSWindow, to target: DetachedTerminalTarget) {
        guard windows[target] !== window else { return }
        if let observer = closeObservers.removeValue(forKey: target) { NotificationCenter.default.removeObserver(observer) }
        windows[target] = window
        closeObservers[target] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.didClose(target, window: window)
            }
        }
        if let position = positions.removeValue(forKey: target) {
            let screen = NSScreen.screens.first { $0.frame.contains(position) } ?? window.screen
            if let screen {
                let origin = Self.clampedOrigin(
                    CGPoint(x: position.x - 100, y: position.y - window.frame.height + 20),
                    size: window.frame.size, visibleFrame: screen.visibleFrame
                )
                window.setFrameOrigin(origin)
            }
        }
    }

    func didClose(_ target: DetachedTerminalTarget, window: NSWindow) {
        guard windows[target] === window else { return }
        if let observer = closeObservers.removeValue(forKey: target) { NotificationCenter.default.removeObserver(observer) }
        windows.removeValue(forKey: target)
        positions.removeValue(forKey: target)
        targets.remove(target)
    }

    @discardableResult
    func focus(hostID: String?, windowID: String) -> Bool {
        guard
            let target = DetachedTerminalTarget(hostID: hostID, windowID: windowID),
            targets.contains(target) else { return false }
        if let window = windows[target] {
            // A disconnected display must not strand the window off-screen.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) {
                window.center()
            }
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func close(_ target: DetachedTerminalTarget) {
        windows[target]?.performClose(nil)
    }

    func request(_ action: Action, from target: DetachedTerminalTarget) {
        mainRequest = Request(target: target, action: action)
    }

    static func clampedOrigin(_ origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: max(visibleFrame.minX, min(origin.x, visibleFrame.maxX - size.width)),
            y: max(visibleFrame.minY, min(origin.y, visibleFrame.maxY - size.height))
        )
    }

    /// A returning right-side tab must not also become the left renderer.
    static func mainSelection(target: String, windows: [(stableID: String, id: String)], rightSide: Set<String>) -> String? {
        if !rightSide.contains(target) { return windows.first { $0.stableID == target }?.id }
        return windows.first { !rightSide.contains($0.stableID) }?.id
    }
}
