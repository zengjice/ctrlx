import CtrlxNetworking
import Foundation
import Testing

struct AgentHookTrustWireTests {
    @Test(arguments: [AgentHookTrustResult.approved, .alreadyTrusted])
    func preservesApprovalResult(result: AgentHookTrustResult) throws {
        let response = CommandResponseMessage(commandId: UUID(), success: true, agentHookTrust: result)
        let decoded = try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response))
        #expect(decoded.success)
        #expect(decoded.agentHookTrust == result)
    }

    @Test("Older Hosts cannot confirm new approval with a generic success response")
    func legacySuccessHasNoApprovalResult() throws {
        let data = Data("{\"commandId\":\"00000000-0000-0000-0000-000000000001\",\"success\":true}".utf8)
        let response = try JSONDecoder().decode(CommandResponseMessage.self, from: data)
        #expect(response.success)
        #expect(response.agentHookTrust == nil)
    }

    @Test
    func roundTripAndLegacyCapability() throws {
        let identity = WorkspacePaneIdentity(serverID: "fixture:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let command = TrustAgentHooks(workspacePane: identity).commandType
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(command)) == command)
        var state = SessionStateMessage(pairId: "a", paneStates: [:], supportsAgentHookTrust: true)
        #expect(state.supportsAgentHookTrust == true)
        #expect(state.withPairId("b").supportsAgentHookTrust == true)
        state = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(SessionStateMessage(pairId: "a", paneStates: [:])))
        #expect(state.supportsAgentHookTrust == nil)
    }
}
