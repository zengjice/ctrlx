import CtrlxNetworking
import Foundation
import Testing

struct AgentHookTrustWireTests {
    @Test("Refresh requires an explicit request and response; approval status stays compatible")
    func refreshCompatibility() throws {
        let identity = WorkspacePaneIdentity(serverID: "fixture", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let request = TrustAgentHooks(workspacePane: identity)
        #expect(request.refreshIfTrusted == true)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json.removeValue(forKey: "refreshIfTrusted")
        let legacyRequest = try JSONDecoder().decode(TrustAgentHooks.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacyRequest.refreshIfTrusted == nil)
        let response = CommandResponseMessage(commandId: UUID(), success: true, agentHookTrust: .alreadyTrusted, agentHooksRefreshed: true)
        let data = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: data).agentHooksRefreshed == true)
        struct OldResponse: Decodable { let agentHookTrust: AgentHookTrustResult }
        #expect(try JSONDecoder().decode(OldResponse.self, from: data).agentHookTrust == .alreadyTrusted)
    }

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
        #expect(response.agentHooksRefreshed == nil)
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
