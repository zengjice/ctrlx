import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct SessionStoreModelShortcutsTests {
    private let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
    private let hostID = UUID()
    private var scope: WorkspaceIdentityScope {
        .init(hostID: hostID, serverID: pane.serverID)
    }

    private let initial = AgentModelShortcutPreferences(hidden: .init(models: ["hidden"]), defaults: .init(efforts: ["low"]), revision: 1)
    private let edited = AgentModelShortcutPreferences(hidden: .init(models: ["hidden", "another"]), defaults: .init(efforts: ["low"]), revision: 2)

    private func state(_ preferences: AgentModelShortcutPreferences?, pair: String = "pair", identity: WorkspacePaneIdentity? = nil) -> SessionStateMessage {
        let identity = identity ?? pane
        return .init(
            pairId: pair,
            paneStates: ["%1": .init(paneId: "%1", sessionName: "project", tmuxWindowId: "@1", workspaceIdentity: identity)],
            agentModelShortcuts: preferences.map { [identity.windowID: $0] },
            workspaceIdentity: .init(hostID: hostID, serverID: identity.serverID)
        )
    }

    @Test("A Host update reaches both Viewers and a reconnect without cross-Host leakage")
    func sharedState() {
        let first = SessionStore(), second = SessionStore()
        for store in [first, second] {
            store.handleStateUpdate(state(initial))
            store.handleStateUpdate(state(initial, pair: "other"))
            store.handleStateUpdate(state(edited))
            #expect(store.agentModelShortcutsByHost["pair"]?[pane.windowID] == edited)
            #expect(store.agentModelShortcutsByHost["other"]?[pane.windowID] == initial)
        }
        second.clearSessions(for: "pair")
        #expect(second.agentModelShortcutsByHost["pair"] == nil)
        second.handleStateUpdate(state(edited))
        #expect(second.agentModelShortcutsByHost["pair"]?[pane.windowID] == edited)
    }

    @Test("A late push or acknowledgement cannot undo newer edits")
    func delayedReplies() {
        let store = SessionStore()
        store.handleStateUpdate(state(initial))
        store.acceptAgentModelShortcuts(edited, pane: pane, hostID: "pair", scope: scope)
        store.handleStateUpdate(state(initial))
        store.acceptAgentModelShortcuts(initial, pane: pane, hostID: "pair", scope: scope)
        #expect(store.agentModelShortcutsByHost["pair"]?[pane.windowID] == edited)
    }

    @Test("A new tmux scope can start a lower revision and rejects the old command reply")
    func replacedWorkspace() {
        let store = SessionStore()
        store.handleStateUpdate(state(edited))
        var next = pane
        next.serverID = "replacement"
        store.handleStateUpdate(state(initial, identity: next))
        store.acceptAgentModelShortcuts(edited, pane: pane, hostID: "pair", scope: scope)
        #expect(store.agentModelShortcutsByHost["pair"]?[pane.windowID] == initial)
    }

    @Test("Closing a tab or switching to a legacy Host clears authority; delayed replies cannot revive it")
    func closedOrLegacy() {
        let store = SessionStore()
        store.handleStateUpdate(state(edited))
        store.handleStateUpdate(.init(pairId: "pair", paneStates: [:], agentModelShortcuts: [pane.windowID: edited], workspaceIdentity: scope))
        #expect(store.agentModelShortcutsByHost["pair"] == [:])
        store.acceptAgentModelShortcuts(edited, pane: pane, hostID: "pair", scope: scope)
        #expect(store.agentModelShortcutsByHost["pair"] == [:])
        store.handleStateUpdate(state(nil))
        #expect(store.agentModelShortcutsByHost["pair"] == nil)
        store.acceptAgentModelShortcuts(edited, pane: pane, hostID: "pair", scope: scope)
        #expect(store.agentModelShortcutsByHost["pair"] == nil)
    }

    @Test("Shared configuration survives pair routing and old messages remain readable")
    func wireCompatibility() throws {
        let message = state(edited).withPairId("routed")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.pairId == "routed")
        #expect(decoded.agentModelShortcuts?[pane.windowID] == edited)
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state(nil)))
        #expect(old.agentModelShortcuts == nil)
        let legacySnapshot = try JSONDecoder().decode(AgentModelShortcutPreferences.self, from: Data(#"{"hidden":{"models":["legacy"],"efforts":[]}}"#.utf8))
        #expect(legacySnapshot.revision == nil && legacySnapshot.hidden.models == ["legacy"])
        let request = SetAgentModelShortcuts(pane: pane, hidden: edited.hidden)
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType)) == request.commandType)
        let response = CommandResponseMessage(commandId: UUID(), success: true, agentModelShortcutPreferences: edited)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).agentModelShortcutPreferences == edited)
    }
}
