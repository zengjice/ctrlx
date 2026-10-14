import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Pane task activity compatibility")
struct PaneActivityTests {
    @Test("A full snapshot sends task activity at whole-second precision")
    func roundTrip() throws {
        let activity = Date(timeIntervalSince1970: 1_234.999)
        let snapshot = SessionStateMessage(pairId: "", paneStates: [
            "%1": PaneState(paneId: "%1", sessionName: "work", lastAgentActivityAt: activity),
        ]).withPairId("host")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionStateMessage.self, from: encoder.encode(snapshot))
        #expect(decoded.pairId == "host")
        #expect(decoded.paneStates["%1"]?.lastAgentActivityAt == Date(timeIntervalSince1970: 1_234))
    }

    @Test("An older Host snapshot decodes without fabricating task activity")
    func decodesLegacySnapshot() throws {
        let pane = PaneState(
            paneId: "%1", sessionName: "work",
            agentSession: AgentSession(paneId: "%1", state: .idle),
            lastAgentActivityAt: Date(timeIntervalSince1970: 1_234)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(pane)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lastAgentActivityAt")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PaneState.self, from: legacy)
        #expect(decoded.lastAgentActivityAt == nil)
        #expect(decoded.sessionName == "work")
        #expect(decoded.agentSession?.state == .idle)
    }
}
