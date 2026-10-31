import CtrlxNetworking

public enum AgentHookTrustMenu {
    public static let title = "Trust All Pending Hooks"
    public static let explanation = "Approves all pending hooks, including other plugins and configuration sources."

    public static func isReady(_ pane: PaneState) -> Bool {
        guard
            let session = pane.agentSession, session.pluginID == "codex",
            pane.workspaceIdentity != nil, !session.state.isActiveWorking,
            session.state.openForm == nil, pane.editorSession == nil else { return false }
        return true
    }
}

#if os(macOS)
    import SwiftUI

    public extension AgentHookTrustMenu {
        @MainActor
        static func items(panes: [PaneState], isEnabled: Bool, approve: ((PaneState) -> Void)?) -> [ContextMenuItem] {
            guard let approve else { return [] }
            let sources = panes.filter { $0.agentSession?.pluginID == "codex" }
            guard let first = sources.first else { return [] }
            if sources.count == 1 {
                return [.button(title: title, symbol: .shield, isEnabled: isEnabled && isReady(first), accessibilityLabel: "\(title). \(explanation)") { approve(first) }]
            }
            return [.submenu(title: title, symbol: .shield, isEnabled: isEnabled, items: sources.map { pane in
                .button(title: "\(pane.windowName) · \(pane.paneId)", isEnabled: isReady(pane), accessibilityLabel: explanation) { approve(pane) }
            })]
        }
    }
#endif
