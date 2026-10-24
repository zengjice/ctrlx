import Crypto
import CtrlxEncryption
import CtrlxNetworking
import Foundation
import Testing

struct AgentWorkflowWireTests {
    @Test
    func runtimeIssueRoundTripsAndOlderInstancesStillDecode() throws {
        let instance = AgentWorkflowInstance(
            hostID: UUID(), pluginID: "codex", processID: 42, processRuntimeID: "runtime",
            workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "native", displayName: "Developer", workingDirectory: "/work",
            capabilities: nil, readiness: .unavailable, capabilityIssue: "CLI version is not verified."
        )
        let data = try JSONEncoder().encode(instance)
        #expect(try JSONDecoder().decode(AgentWorkflowInstance.self, from: data) == instance)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "capabilityIssue")
        let decoded = try JSONDecoder().decode(AgentWorkflowInstance.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.id == instance.id && decoded.capabilityIssue == nil)
    }

    @Test(arguments: [1, AgentWorkflowWire.version])
    func capabilitySurvivesPairRoutingAndOldHostDecodeDefaultsToUnavailable(version: Int) throws {
        let message = SessionStateMessage(pairId: "one", paneStates: [:], agentWorkflowVersion: version, workflowAgentPluginIDs: ["codex", "claude-code"])
        let routed = message.withPairId("two")
        #expect(routed.agentWorkflowVersion == version)
        #expect(routed.workflowAgentPluginIDs == ["codex", "claude-code"])
        #expect(routed.pairId == "two")
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8))
        #expect(decoded.agentWorkflowVersion == nil)
        #expect(decoded.workflowAgentPluginIDs == nil)
    }

    @Test
    func commandAndOptionalResponseRoundTrip() throws {
        let command = ManageAgentWorkflows(.start(definitionID: UUID(), expectedRevision: 3, requestID: UUID(), authorizationExpiresAt: .init(timeIntervalSince1970: 100)), expectedHostID: UUID())
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(command.commandType)) == command.commandType)
        #expect(command.commandType.requiresResponse)
        let id = UUID()
        let legacy = CommandResponseMessage(commandId: id, success: true)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(legacy)).agentWorkflow == nil)
        let response = AgentWorkflowResponse(hostID: UUID())
        let current = CommandResponseMessage(commandId: id, success: true, agentWorkflow: response)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(current)).agentWorkflow == response)
    }

    @Test
    func largestEscapedTextPageFitsTheEncryptedRelayEnvelope() throws {
        var response = AgentWorkflowResponse(hostID: UUID())
        let text = String(repeating: "\u{0000}", count: AgentWorkflowWire.textPageBytes)
        response.text = .init(text: text, nextOffset: AgentWorkflowWire.textPageBytes, totalBytes: 1_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(try encoder.encode(response).count <= AgentWorkflowWire.maximumEncodedBytes)
        let message = WebSocketMessage.commandResponse(.init(commandId: UUID(), success: true, agentWorkflow: response))
        let inner = try encoder.encode(message)
        let key = SymmetricKey(size: .bits256)
        let sealed = try ChaChaPoly.seal(inner, using: key)
        let envelope = WebSocketMessage.encrypted(.init(payload: EncryptedPayload(ciphertext: sealed.combined, senderKeyId: UUID().uuidString)))
        #expect(try encoder.encode(envelope).count < RelayPayloadLimits.maxWebSocketFrameBytes)
        #expect(try ChaChaPoly.open(sealed, using: key) == inner)
    }
}
