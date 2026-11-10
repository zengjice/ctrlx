import CtrlxNetworking
import SwiftUI

@MainActor
public struct AgentRestartMenu: View {
    private let panes: [PaneState]
    private let unavailableReason: String?
    private let busyPaneIDs: Set<String>
    private let choose: (RestartAgentSession) -> Void

    public init(panes: [PaneState], unavailableReason: String? = nil, busyPaneIDs: Set<String> = [], choose: @escaping (RestartAgentSession) -> Void) {
        self.panes = panes
        self.unavailableReason = unavailableReason
        self.busyPaneIDs = busyPaneIDs
        self.choose = choose
    }

    private var requests: [RestartAgentSession] {
        panes.compactMap { pane in
            guard
                let source = AgentForkSource(pane: pane), source.workspaceIdentity != nil,
                let runtime = pane.agentSession?.processRuntimeID else { return nil }
            return RestartAgentSession(source: source, runtimeID: runtime)
        }
    }

    private var reason: String? {
        unavailableReason ?? (requests.isEmpty ? "Resume requires a verified Codex or Claude Code conversation and process identity." : nil)
    }

    private func title(_ request: RestartAgentSession) -> String {
        let pane = panes.first { $0.paneId == request.source.paneID }
        return "Pane \((pane?.paneIndex ?? 0) + 1) · \(pane?.agentSession?.displayName ?? "Agent")"
    }

    public var body: some View {
        if panes.contains(where: { $0.agentSession != nil }) {
            if requests.count == 1, let request = requests.first, reason == nil {
                Button { choose(request) } label: { Label("Exit and Resume", symbol: .arrowClockwise) }
                    .disabled(busyPaneIDs.contains(request.source.paneID))
                    .accessibilityIdentifier("agentRestart.\(request.source.paneID)")
            } else {
                Menu {
                    ForEach(requests) { request in
                        Button(title(request)) { choose(request) }.disabled(reason != nil || busyPaneIDs.contains(request.source.paneID))
                    }
                    if let reason {
                        Text(reason)
                    }
                } label: { Label("Exit and Resume", symbol: .arrowClockwise) }
                    .accessibilityIdentifier("agentRestart.menu")
            }
        }
    }

    #if os(macOS)
        public var contextMenuItems: [ContextMenuItem] {
            guard panes.contains(where: { $0.agentSession != nil }) else { return [] }
            if requests.count == 1, let request = requests.first, reason == nil {
                return [.button(title: "Exit and Resume", symbol: .arrowClockwise, isEnabled: !busyPaneIDs.contains(request.source.paneID)) { choose(request) }]
            }
            var items = requests.map { request in
                ContextMenuItem.button(title: title(request), isEnabled: reason == nil && !busyPaneIDs.contains(request.source.paneID)) { choose(request) }
            }
            if let reason {
                items.append(.button(title: reason, isEnabled: false) { })
            }
            return [.submenu(title: "Exit and Resume", symbol: .arrowClockwise, items: items)]
        }
    #endif
}
