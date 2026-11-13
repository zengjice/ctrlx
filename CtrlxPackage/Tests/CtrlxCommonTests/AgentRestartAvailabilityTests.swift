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

    @Test("Logout requires its own capability even when the Host can restart")
    func logoutCapabilityGate() {
        let store = SessionStore()
        store.handleStateUpdate(.init(pairId: "one", paneStates: [:], supportsAgentRestart: true, supportsAgentLogout: true))
        store.handleStateUpdate(.init(pairId: "two", paneStates: [:], supportsAgentRestart: true))
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: true, logoutBeforeResume: true) == nil)
        #expect(store.agentRestartUnavailableReason(hostID: "two", isConnected: true) == nil)
        #expect(store.agentRestartUnavailableReason(hostID: "two", isConnected: true, logoutBeforeResume: true) != nil)
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: false, logoutBeforeResume: true) != nil)
        store.handleStateUpdate(.init(pairId: "one", paneStates: [:], supportsAgentRestart: true))
        #expect(store.agentRestartUnavailableReason(hostID: "one", isConnected: true, logoutBeforeResume: true) != nil)
        store.handleStateUpdate(.init(pairId: "one", paneStates: [:], supportsAgentRestart: true, supportsAgentLogout: true))
        store.clearSessions(for: "one")
        #expect(!store.hostsSupportingAgentLogout.contains("one"))
    }

    #if os(macOS)
        @Test("A verified Agent has a direct action; shells and pending restarts cannot trigger it", arguments: [false, true])
        func menuTargets(logout: Bool) throws {
            var pane = PaneState(paneId: "%1", sessionName: "work", currentPath: "/repo", workspaceIdentity: .init(serverID: "12:34", sessionID: UUID(), windowID: UUID(), paneID: UUID()))
            #expect(AgentRestartMenu(panes: [pane], logoutBeforeResume: logout, choose: { _ in }).contextMenuItems.isEmpty)
            pane.agentSession = .init(paneId: "%1", pluginID: "codex", processRuntimeID: "original")
            pane.claudeSessionID = UUID().uuidString
            var chosen: RestartAgentSession?
            let items = AgentRestartMenu(panes: [pane], logoutBeforeResume: logout, choose: { chosen = $0 }).contextMenuItems
            guard case let .button(title, _, enabled, _, action) = try #require(items.first) else {
                Issue.record("Expected a direct restart action")
                return
            }
            #expect(enabled)
            #expect(title == (logout ? "Log Out and Log In" : "Exit and Resume"))
            action()
            #expect(chosen?.source.paneID == "%1" && chosen?.source.sessionID == pane.claudeSessionID)
            #expect(chosen?.logoutBeforeResume == logout)
            let firstRequestID = try #require(chosen?.requestID)
            action()
            #expect(chosen?.requestID != firstRequestID)
            let busy = AgentRestartMenu(panes: [pane], busyPaneIDs: ["%1"], logoutBeforeResume: logout, choose: { _ in }).contextMenuItems
            guard case let .button(_, _, busyEnabled, _, _) = try #require(busy.first) else {
                Issue.record("Expected a disabled restart action")
                return
            }
            #expect(!busyEnabled)
            let unavailable = AgentRestartMenu(panes: [pane], unavailableReason: "Update this Host", logoutBeforeResume: logout, choose: { _ in }).contextMenuItems
            guard
                case let .submenu(_, _, _, _, children) = try #require(unavailable.first),
                case let .button(_, _, available, _, _) = try #require(children.first) else {
                Issue.record("Expected an unavailable action")
                return
            }
            #expect(!available)
        }
    #endif
}
