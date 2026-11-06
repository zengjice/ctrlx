import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentHookTrustMenuTests {
    private func pane(_ id: String, plugin: String = "codex", working: Bool = false) -> PaneState {
        .init(paneId: id, agentSession: .init(paneId: id, pluginID: plugin, state: working ? .working : .idle), workspaceIdentity: .init(serverID: "fixture", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
    }

    @Test
    func onlyReadyCodexPanes() {
        #expect(AgentHookTrustMenu.isReady(pane("%1")))
        #expect(AgentHookTrustMenu.isReady(pane("%1", working: true)))
        #expect(!AgentHookTrustMenu.isReady(pane("%1", plugin: "claude-code")))
        let missing = PaneState(paneId: "%1", agentSession: .init(paneId: "%1", pluginID: "codex"))
        #expect(missing.workspaceIdentity == nil)
        #expect(!AgentHookTrustMenu.isReady(missing))
    }

    @Test("Approval and refresh never claim that subsequent hook execution was confirmed")
    func executionFeedback() {
        for message in [AgentHookTrustMenu.feedbackMessage(for: .approved), AgentHookTrustMenu.feedbackMessage(for: .alreadyTrusted, refreshed: true)] {
            #expect(message.contains("Hook execution has not been confirmed"))
        }
        #expect(AgentHookTrustMenu.feedbackMessage(for: .alreadyTrusted).contains("did not confirm refreshing"))
    }

    #if os(macOS)
        @Test("Mac menus preserve the chosen pane and disclose all-source scope")
        func menuRoutesExplicitSources() throws {
            let panes = [pane("%1"), pane("%2"), pane("%3", plugin: "claude-code")]
            var selected: String?
            let items = AgentHookTrustMenu.items(panes: panes, isEnabled: true, approve: { selected = $0.paneId })
            guard case let .submenu(title, _, _, _, children) = try #require(items.first) else {
                Issue.record("Multiple Codex panes require an explicit source choice")
                return
            }
            #expect(title == "Trust and Refresh Hooks")
            #expect(children.count == 2)
            guard case let .button(_, _, _, hint, action) = children[1] else { return }
            #expect(hint?.contains("other plugins") == true)
            action()
            #expect(selected == "%2")
            #expect(AgentHookTrustMenu.items(panes: panes, isEnabled: true, approve: nil).isEmpty)
        }
    #endif
}
