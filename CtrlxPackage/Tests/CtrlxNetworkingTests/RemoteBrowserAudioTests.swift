import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Browser audio wire")
struct RemoteBrowserAudioTests {
    @Test
    func boundedAudioIsEncryptedAndRoundTrips() throws {
        let audio = RemoteBrowserAudio(
            tabID: UUID(),
            surfaceID: UUID(),
            controlID: UUID(),
            streamID: UUID(),
            sequence: 3,
            packets: [Data(repeating: 255, count: 4_096)],
            magicCookie: Data([1, 2])
        )
        #expect(audio.isValid)
        let message = WebSocketMessage.browserAudio(audio)
        #expect(message.shouldEncrypt)
        let encoded = try JSONEncoder().encode(message)
        #expect(encoded.count < 64 * 1_024)
        let copy = try JSONDecoder().decode(WebSocketMessage.self, from: encoded)
        guard case let .browserAudio(value) = copy else { Issue.record("Missing audio")
            return
        }
        #expect(value == audio)
        let request = BrowseBrowser(
            sessionName: "s",
            tabID: audio.tabID,
            surfaceID: audio.surfaceID,
            controlID: audio.controlID,
            operation: .audio(streamID: audio.streamID, revision: 1, enabled: true)
        )
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType)) == request.commandType)
    }

    @Test
    func oldHostsStaySilentAndCapabilitySurvivesPairRouting() throws {
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"a","paneStates":{},"homeDirectory":""}"#.utf8))
        #expect(old.supportsBrowserAudio == nil)
        let updated = SessionStateMessage(pairId: "a", paneStates: [:], supportsBrowserAudio: true).withPairId("b")
        #expect(updated.supportsBrowserAudio == true)
    }

    @Test(arguments: [0, 5, 9])
    func rejectsUnboundedPackets(_ count: Int) {
        let value = RemoteBrowserAudio(
            tabID: UUID(),
            surfaceID: UUID(),
            controlID: UUID(),
            streamID: UUID(),
            sequence: 1,
            packets: Array(repeating: Data(repeating: 1, count: 4_096), count: count)
        )
        #expect(!value.isValid)
    }
}
