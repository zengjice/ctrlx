import CtrlxNetworking
import SwiftUI

@MainActor
public struct AgentRestartMenu: View {
    private let panes: [PaneState]
    private let unavailableReason: String?
    private let busyPaneIDs: Set<String>
    private let logoutBeforeResume: Bool
    private let choose: (RestartAgentSession) -> Void

    public init(panes: [PaneState], unavailableReason: String? = nil, busyPaneIDs: Set<String> = [], logoutBeforeResume: Bool = false, choose: @escaping (RestartAgentSession) -> Void) {
        self.panes = panes
        self.unavailableReason = unavailableReason
        self.busyPaneIDs = busyPaneIDs
        self.logoutBeforeResume = logoutBeforeResume
        self.choose = choose
    }

    private var requests: [RestartAgentSession] {
        panes.compactMap { pane in
            guard
                let source = AgentForkSource(pane: pane), source.workspaceIdentity != nil,
                let runtime = pane.agentSession?.processRuntimeID else { return nil }
            return RestartAgentSession(source: source, runtimeID: runtime, logoutBeforeResume: logoutBeforeResume)
        }
    }

    private var reason: String? {
        unavailableReason ?? (requests.isEmpty ? "Resume requires a verified Codex or Claude Code conversation and process identity." : nil)
    }

    private var actionTitle: String {
        logoutBeforeResume ? "Log Out and Log In" : "Exit and Resume"
    }

    private var accessibilityPrefix: String {
        logoutBeforeResume ? "agentLogout" : "agentRestart"
    }

    private func title(_ request: RestartAgentSession) -> String {
        let pane = panes.first { $0.paneId == request.source.paneID }
        return "Pane \((pane?.paneIndex ?? 0) + 1) · \(pane?.agentSession?.displayName ?? "Agent")"
    }

    public var body: some View {
        if panes.contains(where: { $0.agentSession != nil }) {
            if requests.count == 1, let request = requests.first, reason == nil {
                Button { choose(request) } label: { Label(actionTitle, symbol: .arrowClockwise) }
                    .disabled(busyPaneIDs.contains(request.source.paneID))
                    .accessibilityIdentifier("\(accessibilityPrefix).\(request.source.paneID)")
            } else {
                Menu {
                    ForEach(requests) { request in
                        Button(title(request)) { choose(request) }.disabled(reason != nil || busyPaneIDs.contains(request.source.paneID))
                    }
                    if let reason {
                        Text(reason)
                    }
                } label: { Label(actionTitle, symbol: .arrowClockwise) }
                    .accessibilityIdentifier("\(accessibilityPrefix).menu")
            }
        }
    }

    #if os(macOS)
        public var contextMenuItems: [ContextMenuItem] {
            guard panes.contains(where: { $0.agentSession != nil }) else { return [] }
            if requests.count == 1, let request = requests.first, reason == nil {
                return [.button(title: actionTitle, symbol: .arrowClockwise, isEnabled: !busyPaneIDs.contains(request.source.paneID)) { choose(request) }]
            }
            var items = requests.map { request in
                ContextMenuItem.button(title: title(request), isEnabled: reason == nil && !busyPaneIDs.contains(request.source.paneID)) { choose(request) }
            }
            if let reason {
                items.append(.button(title: reason, isEnabled: false) { })
            }
            return [.submenu(title: actionTitle, symbol: .arrowClockwise, items: items)]
        }
    #endif
}
