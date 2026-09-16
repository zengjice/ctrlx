import CtrlxNetworking
import Foundation
import Observation
import SwiftUI

/// A mounted native terminal's existing input queue. No independent transport or
/// task chain: toolbar input joins the exact queue used by that pane's keyboard.
@MainActor
@Observable
final class TerminalQuickActionEndpoint {
    let id = UUID()
    let hostID: String? // nil is the local host; never share identity with a remote pane.
    let paneID: String
    var isReady = false
    private(set) var inputRevision: UInt64 = 0
    @ObservationIgnored private(set) var isMounted = true
    private let isVisible: @MainActor () -> Bool
    private let enqueue: @MainActor ([TmuxKey]) -> Void

    init(hostID: String?, paneID: String,
         isVisible: @escaping @MainActor () -> Bool,
         enqueue: @escaping @MainActor ([TmuxKey]) -> Void) {
        self.hostID = hostID
        self.paneID = paneID
        self.isVisible = isVisible
        self.enqueue = enqueue
    }

    var isAvailable: Bool { isMounted && isVisible() }

    func recordInput() { inputRevision &+= 1 }

    func invalidate() {
        // Synchronous guard, without publishing SwiftUI state during dismantle.
        isMounted = false
    }

    func send(_ keys: [TmuxKey]) {
        recordInput() // Consume the captured action before dispatch; reject double clicks.
        enqueue(keys)
    }
}

/// Scene-local selection driven by native first-responder events, not tmux's
/// active pane or MainView's left-hand tab. Opening a popover retains this target.
@MainActor
@Observable
final class TerminalQuickActionRouter {
    struct Token: Equatable, Sendable {
        let endpointID: UUID
        let focusRevision: UInt64
        let inputRevision: UInt64
    }

    private(set) var active: TerminalQuickActionEndpoint?
    private var focusRevision: UInt64 = 0

    var token: Token? {
        guard let active else { return nil }
        return Token(endpointID: active.id, focusRevision: focusRevision,
                     inputRevision: active.inputRevision)
    }

    func focus(_ endpoint: TerminalQuickActionEndpoint) {
        guard endpoint.isMounted, active !== endpoint else { return }
        focusRevision &+= 1
        active = endpoint
    }

    func retire(_ endpoint: TerminalQuickActionEndpoint) {
        guard active === endpoint else { return }
        active = nil
    }

    func matches(_ captured: Token?) -> Bool {
        guard let captured, captured == token, let active else { return false }
        return active.isAvailable
    }

    @discardableResult
    func send(_ keys: [TmuxKey], to captured: Token) -> Bool {
        guard matches(captured), let active, active.isReady, !keys.isEmpty else { return false }
        active.send(keys)
        return true
    }
}

extension EnvironmentValues {
    @Entry var terminalQuickActions: TerminalQuickActionRouter? = nil
}
