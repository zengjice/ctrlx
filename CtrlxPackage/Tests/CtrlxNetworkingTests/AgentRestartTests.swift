import Foundation
import Testing
@testable import CtrlxNetworking

struct AgentRestartTests {
    private func pane() -> PaneState {
        .init(
            paneId: "%1",
            sessionName: "work",
            tmuxWindowId: "@2",
            currentPath: "/repo",
            agentSession: .init(paneId: "%1", pluginID: "codex"),
            claudeSessionID: UUID().uuidString,
            workspaceIdentity: .init(serverID: "12:34", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        )
    }

    @Test("Restart retains its request and source identities across the command wire")
    func wire() throws {
        let source = try #require(AgentForkSource(pane: pane()))
        let request = RestartAgentSession(source: source, runtimeID: "original")
        let message = CommandMessage(paneId: "", command: request.commandType, expectedWorkspacePane: source.workspaceIdentity)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.command == request.commandType && decoded.expectedWorkspacePane == source.workspaceIdentity)
        #expect(decoded.command.requiresResponse)
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":"/Host"}"#.utf8))
        #expect(old.supportsAgentRestart == nil)
        let state = SessionStateMessage(pairId: "one", paneStates: [:], supportsAgentRestart: true)
        #expect(state.withPairId("two").supportsAgentRestart == true)
        let legacyAgent = try JSONDecoder().decode(AgentSession.self, from: Data(#"{"paneId":"%1","pluginID":"codex"}"#.utf8))
        #expect(legacyAgent.processRuntimeID == nil)
        #expect(!request.matches(source, runtimeID: "replacement"))
    }

    @Test("Moves preserve restart intent; a replaced pane, conversation or directory does not", arguments: ["move", "pane", "server", "conversation", "directory", "plugin", "missing-identity"])
    func sourceBinding(change: String) throws {
        var current = pane()
        let request = try RestartAgentSession(source: #require(AgentForkSource(pane: current)), runtimeID: "original")
        switch change {
        case "move":
            current.sessionName = "renamed"
            current.tmuxWindowId = "@9"
            current.workspaceIdentity?.sessionID = UUID()
            current.workspaceIdentity?.windowID = UUID()
        case "pane": current.workspaceIdentity?.paneID = UUID()
        case "server": current.workspaceIdentity?.serverID = "56:78"
        case "conversation": current.claudeSessionID = UUID().uuidString
        case "directory": current.currentPath = "/elsewhere"
        case "plugin": current.agentSession?.pluginID = "claude-code"
        default: current.workspaceIdentity = nil
        }
        #expect(try request.matches(#require(AgentForkSource(pane: current)), runtimeID: "original") == (change == "move"))
    }
}
