import Foundation
import Testing
@testable import CtrlxNetworking

struct TerminalPaneSplitCommandTests {
    @Test("A sized pane split is additive to the legacy split command")
    func splitSizing() throws {
        let legacy = try JSONDecoder().decode(SplitTmuxPane.self, from: Data(#"{"direction":"vertical"}"#.utf8))
        #expect(legacy.direction == .vertical && legacy.sizeFraction == nil)
        let old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(old["sizeFraction"] == nil)
        let request = CommandMessage(paneId: "%2", command: SplitTmuxPane(direction: .vertical, sizeFraction: 1.0 / 6.0).commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(request))
        #expect(decoded.id == request.id && decoded.paneId == request.paneId)
        #expect(decoded.command == request.command)
    }

    @Test("Old Hosts do not offer split sizing and pairing copies preserve the capability")
    func hostCapability() throws {
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(SessionStateMessage(pairId: "old", paneStates: [:])))
        #expect(old.supportsPaneSplitSizing == nil)
        let modern = SessionStateMessage(pairId: "host", paneStates: [:], supportsPaneSplitSizing: true)
        let copied = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(modern.withPairId("viewer")))
        #expect(copied.pairId == "viewer" && copied.supportsPaneSplitSizing == true)
    }
}
