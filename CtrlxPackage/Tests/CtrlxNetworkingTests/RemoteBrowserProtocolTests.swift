import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Remote browser protocol")
struct RemoteBrowserProtocolTests {
    @Test func wireRoundTrip() throws {
        let operations: [RemoteBrowserOperation] = [.create, .frame, .takeControl, .releaseControl,
            .navigate("https://example.com/中文"), .back, .forward, .reload, .close, .fit(width: 390, height: 700),
            .text("中文\nsecond line"), .key(.init("Enter", keyCode: 13)), .pointer(.init(.down, x: 2, y: 5, button: .left))]
        for operation in operations {
            let request = BrowseBrowser(sessionName: "same", tabID: UUID(), surfaceID: UUID(), controlID: UUID(),
                                        generation: 42, operation: operation)
            let copy = try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType))
            #expect(copy == request.commandType)
        }
    }

    @Test func oldHostDoesNotAdvertiseSupport() throws {
        let data = Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8)
        let state = try JSONDecoder().decode(SessionStateMessage.self, from: data)
        #expect(state.supportsBrowserSharing == nil)
        #expect(state.browserTabs == nil)
        let tab = RemoteBrowserTab(id: UUID(), sessionName: "s", title: "page", url: "about:blank", isLoading: false, isAgentOwned: true)
        let updated = SessionStateMessage(pairId: "a", paneStates: [:], supportsBrowserSharing: true, browserTabs: [tab]).withPairId("b")
        #expect(updated.supportsBrowserSharing == true)
        #expect(updated.browserTabs == [tab])
    }

    @Test func frameBudgetFitsEncryptedRelayEnvelope() throws {
        let frame = RemoteBrowserFrame(jpeg: Data(repeating: 1, count: RemoteBrowserFrame.maximumBytes), width: 1200, height: 700, generation: 1)
        #expect(frame.isValid)
        let payload = CommandResponseMessage(commandId: UUID(), success: true, browser: .init(frame: frame))
        let encoded = try JSONEncoder().encode(payload)
        // Encryption adds a second base64 envelope, plus authentication/JSON overhead.
        #expect(encoded.count * 4 / 3 + 8192 < RelayPayloadLimits.maxWebSocketFrameBytes)
        #expect(!RemoteBrowserFrame(jpeg: frame.jpeg + Data([0]), width: 1200, height: 700, generation: 1).isValid)
        #expect(!RemoteBrowserFrame(jpeg: Data([0]), width: .nan, height: 700, generation: 1).isValid)
    }

    @Test func pointerValidation() {
        #expect(RemoteBrowserPointer(.move, x: 50, y: 40, buttons: 1).isValid)
        #expect(!RemoteBrowserPointer(.move, x: -.infinity, y: 40).isValid)
        #expect(!RemoteBrowserPointer(.move, x: 50, y: 40, deltaY: 10_000).isValid)
    }
}
