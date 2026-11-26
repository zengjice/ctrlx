import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Shared terminal layout wire format")
struct SharedTerminalLayoutTests {
    @Test("Session snapshots round-trip layouts and preserve them when assigning a pair ID")
    func snapshotRoundTrip() throws {
        let layout = SharedTerminalLayout(
            leftWindowId: "@1",
            rightWindowIds: ["@2", "@3"],
            selectedRightWindowId: "@3",
            splitRatio: 0.4,
            revision: 7
        )
        let message = SessionStateMessage(
            pairId: "",
            paneStates: [:],
            sharedTerminalLayouts: ["coding": layout]
        )

        let decoded = try JSONDecoder().decode(
            SessionStateMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded.sharedTerminalLayouts == ["coding": layout])
        #expect(message.withPairId("host-1").sharedTerminalLayouts == ["coding": layout])
    }

    @Test("Snapshots from older hosts decode without layout support")
    func legacySnapshot() throws {
        let data = Data(#"{"pairId":"host-1","paneStates":{},"homeDirectory":"/tmp"}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: data)

        #expect(decoded.sharedTerminalLayouts == nil)
    }

    @Test("Viewer layout requests round-trip through the command envelope")
    func commandRoundTrip() throws {
        let request = SetSharedTerminalLayout(
            sessionName: "coding",
            leftWindowId: "@1",
            rightWindowIds: ["@2"],
            selectedRightWindowId: "@2",
            splitRatio: 0.6
        )

        let decoded = try JSONDecoder().decode(
            CommandType.self,
            from: JSONEncoder().encode(request.commandType)
        )

        #expect(decoded == .setSharedTerminalLayout(request))
    }

    @Test("Explicit hidden-terminal removals round-trip and older requests still decode")
    func explicitRemovalsRemainOptional() throws {
        let legacy = Data(#"{"sessionName":"coding","leftWindowId":"@1","rightWindowIds":[],"splitRatio":0.5}"#.utf8)
        #expect(try JSONDecoder().decode(SetSharedTerminalLayout.self, from: legacy).removedRightWindowIds == nil)
        let request = SetSharedTerminalLayout(sessionName: "coding", leftWindowId: "@1", removedRightWindowIds: ["@2", "@3"])
        let decoded = try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType))
        #expect(decoded == .setSharedTerminalLayout(request))
    }
}
