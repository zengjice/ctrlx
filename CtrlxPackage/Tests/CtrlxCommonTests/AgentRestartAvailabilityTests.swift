import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentRestartAvailabilityTests {
    @Test("Restart support is Host scoped and cleared on downgrade or disconnect")
    func capabilityGate() {
        let store = SessionStore()
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: true) != nil)
        store.handleStateUpdate(.init(pairId: "one", paneStates: [:], supportsAgentRestart: true))
        store.handleStateUpdate(.init(pairId: "two", paneStates: [:]))
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: true) == nil)
        #expect(store.agentRestartUnavailableReason(hostID: "two", isConnected: true) != nil)
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: false) != nil)
        store.handleStateUpdate(.init(pairId: "one", paneStates: [:]))
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: true) != nil)
        store.handleStateUpdate(.init(pairId: "one", paneStates: [:], supportsAgentRestart: true))
        store.clearSessions(for: "one")
        #expect(!store.hostsSupportingAgentRestart.contains("one"))
    }

    #if os(macOS)
        @Test("A verified Agent has a direct action; shells and pending restarts cannot trigger it")
        func menuTargets() throws {
            var pane = PaneState(paneId: "%1", sessionName: "work", currentPath: "/repo", workspaceIdentity: .init(serverID: "12:34", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
            #expect(AgentRestartMenu(panes: [pane], choose: { _ in }).contextMenuItems.isEmpty)
            pane.agentSession = .init(paneId: "%1", pluginID: "codex", processRuntimeID: "original")
            pane.claudeSessionID = UUID().uuidString
            var chosen: RestartAgentSession?
            let items = AgentRestartMenu(panes: [pane], choose: { chosen = $0 }).contextMenuItems
            guard case let .button(_, _, enabled, _, action) = try #require(items.first) else {
                Issue.record("Expected a direct restart action")
                return
            }
            #expect(enabled)
            action()
            #expect(chosen?.source.paneID == "%1" && chosen?.source.sessionID == pane.claudeSessionID)
            let busy = AgentRestartMenu(panes: [pane], busyPaneIDs: ["%1"], choose: { _ in }).contextMenuItems
            guard case let .button(_, _, busyEnabled, _, _) = try #require(busy.first) else {
                Issue.record("Expected a disabled restart action")
                return
            }
            #expect(!busyEnabled)
        }
    #endif
}
