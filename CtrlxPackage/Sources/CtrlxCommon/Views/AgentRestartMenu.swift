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

    private struct Source: Identifiable {
        let agent: AgentForkSource
        let runtimeID: String
        var id: String {
            agent.paneID
        }
    }

    private var sources: [Source] {
        panes.compactMap { pane in
            guard
                let source = AgentForkSource(pane: pane), source.workspaceIdentity != nil,
                let runtime = pane.agentSession?.processRuntimeID else { return nil }
            return Source(agent: source, runtimeID: runtime)
        }
    }

    private func choose(_ source: Source) {
        choose(RestartAgentSession(source: source.agent, runtimeID: source.runtimeID, logoutBeforeResume: logoutBeforeResume))
    }

    private var reason: String? {
        unavailableReason ?? (sources.isEmpty ? "Resume requires a verified Codex or Claude Code conversation and process identity." : nil)
    }

    private var actionTitle: String {
        logoutBeforeResume ? "Log Out and Log In" : "Exit and Resume"
    }

    private var accessibilityPrefix: String {
        logoutBeforeResume ? "agentLogout" : "agentRestart"
    }

    private func title(_ source: Source) -> String {
        let pane = panes.first { $0.paneId == source.id }
        return "Pane \((pane?.paneIndex ?? 0) + 1) · \(pane?.agentSession?.displayName ?? "Agent")"
    }

    public var body: some View {
        if panes.contains(where: { $0.agentSession != nil }) {
            if sources.count == 1, let source = sources.first, reason == nil {
                Button { choose(source) } label: { Label(actionTitle, symbol: .arrowClockwise) }
                    .disabled(busyPaneIDs.contains(source.id))
                    .accessibilityIdentifier("\(accessibilityPrefix).\(source.id)")
            } else {
                Menu {
                    ForEach(sources) { source in
                        Button(title(source)) { choose(source) }.disabled(reason != nil || busyPaneIDs.contains(source.id))
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
            if sources.count == 1, let source = sources.first, reason == nil {
                return [.button(title: actionTitle, symbol: .arrowClockwise, isEnabled: !busyPaneIDs.contains(source.id)) { choose(source) }]
            }
            var items = sources.map { source in
                ContextMenuItem.button(title: title(source), isEnabled: reason == nil && !busyPaneIDs.contains(source.id)) { choose(source) }
            }
            if let reason {
                items.append(.button(title: reason, isEnabled: false) { })
            }
            return [.submenu(title: actionTitle, symbol: .arrowClockwise, items: items)]
        }
    #endif
}
