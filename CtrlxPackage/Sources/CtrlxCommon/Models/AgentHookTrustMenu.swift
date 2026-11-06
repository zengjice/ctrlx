import CtrlxNetworking

public enum AgentHookTrustMenu {
    public static let title = "Trust and Refresh Hooks"
    public static let explanation = "Approves all pending hooks, including other plugins and configuration sources. If already trusted, refreshes this conversation by briefly turning an enabled CtrlX hook off and back on."

    public static func feedbackMessage(for result: AgentHookTrustResult?, refreshed: Bool = false) -> String {
        switch result {
        case .approved:
            "Pending hooks were approved in this conversation. Hook on/off settings were kept.\n\nHook execution has not been confirmed. Check that the next task reports Agent activity in CtrlX."
        case .alreadyTrusted:
            refreshed
                ? "Hooks were already trusted. This conversation's hook configuration was refreshed, and the original hook on/off settings were restored.\n\nHook execution has not been confirmed. Check that the next task reports Agent activity in CtrlX."
                : "Codex already reports all hooks as trusted. This Host did not confirm refreshing the running configuration.\n\nUpdate the Host, or open /hooks → UserPromptSubmit in this tab and turn an already-enabled CtrlX hook off, then back on. Wait for each change to appear before closing the panel."
        case nil:
            "This Host did not report whether new approval was performed. Update the Host for detailed results. Check /hooks in this conversation; a success response alone does not confirm that its running configuration was refreshed."
        }
    }

    public static func isReady(_ pane: PaneState) -> Bool {
        // Menu availability is metadata-only. A stale Working event must not
        // prevent requesting the Host's live idle verification.
        guard
            let session = pane.agentSession, session.pluginID == "codex",
            pane.workspaceIdentity != nil,
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
