import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct AgentWorkflowCreationTests {
    @Test
    func discoveryAfterCreationCannotSelectReusedPaneOnAnotherHostOrServer() {
        let host = UUID()
        let created = AgentWorkflowCreatedAgent(paneID: "%1", scope: .init(hostID: host, serverID: "original-server"), pluginID: "codex")
        func instance(hostID: UUID, serverID: String, paneID: String = "%1", pluginID: String = "codex") -> AgentWorkflowInstance {
            .init(
                hostID: hostID,
                pluginID: pluginID,
                processID: 100,
                processRuntimeID: "100:start",
                workspacePane: .init(serverID: serverID, sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: paneID,
                conversationID: "native",
                displayName: "Same label",
                workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 100_000),
                readiness: .ready
            )
        }
        #expect(created.matches(instance(hostID: host, serverID: "original-server")))
        #expect(!created.matches(instance(hostID: UUID(), serverID: "original-server")))
        #expect(!created.matches(instance(hostID: host, serverID: "replacement-server")))
        #expect(!created.matches(instance(hostID: host, serverID: "original-server", paneID: "%2")))
        #expect(!created.matches(instance(hostID: host, serverID: "original-server", pluginID: "claude-code")))
    }
}
