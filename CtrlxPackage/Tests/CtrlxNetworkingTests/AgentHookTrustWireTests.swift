import CtrlxNetworking
import Foundation
import Testing

struct AgentHookTrustWireTests {
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
