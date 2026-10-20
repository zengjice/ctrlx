import CtrlxEncryption
import Foundation
import Testing
@testable import CtrlxNetworking

struct RemoteSimulatorProtocolTests {
    @Test
    func oldPeersAndPerConnectionCopiesPreserveOptionalCapabilities() throws {
        let old = try JSONDecoder().decode(
            SessionStateMessage.self,
            from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8)
        )
        #expect(old.supportsSimulatorViewing == nil && old.supportsPaneSimulator == nil && old.simulatorTabs == nil)
        let tab = RemoteSimulatorTab(
            id: UUID(),
            sessionName: "work",
            windowID: "@2",
            sourcePaneID: "%1",
            title: "iPhone",
            runtime: "iOS 27",
            isPrimary: true
        )
        let state = SessionStateMessage(pairId: "a", paneStates: [:], supportsSimulatorViewing: true, supportsPaneSimulator: true, simulatorTabs: [tab]).withPairId("b")
        let copy = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(state))
        #expect(copy.pairId == "b" && copy.supportsSimulatorViewing == true && copy.supportsPaneSimulator == true && copy.simulatorTabs == [tab])
        let request = BrowseSimulator(sessionName: "work", tabID: tab.id, frameMaxDimension: 1_280)
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(request.commandType)) == request.commandType)
        let frame = RemoteSimulatorFrame(jpeg: Data([1, 2]), width: 320, height: 640)
        let response = CommandResponseMessage(commandId: UUID(), success: true, simulator: .init(tab: tab, frame: frame), simulatorTab: tab)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).simulator == response.simulator)
        let legacy = try JSONDecoder().decode(
            CommandResponseMessage.self,
            from: JSONEncoder().encode(CommandResponseMessage.success(for: UUID()))
        )
        #expect(legacy.simulator == nil && legacy.simulatorTab == nil)
        let open = OpenPaneSimulator(sessionName: "work", sourcePaneID: "%1")
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(open.commandType)) == open.commandType)
        #expect(try JSONDecoder().decode(CommandResponseMessage.self, from: JSONEncoder().encode(response)).simulatorTab == tab)
    }

    @Test
    func maximumPreviewFitsTheEncryptedRelayEnvelope() throws {
        let tab = RemoteSimulatorTab(
            id: UUID(),
            sessionName: "work",
            windowID: "@2",
            sourcePaneID: "%1",
            title: "iPhone",
            runtime: "iOS 27",
            isPrimary: true
        )
        let response = CommandResponseMessage(commandId: UUID(), success: true, simulator: .init(
            tab: tab,
            frame: .init(jpeg: Data(repeating: 0xA5, count: RemoteSimulatorFrame.maximumBytes), width: 2_560, height: 2_560)
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let inner = try encoder.encode(WebSocketMessage.commandResponse(response))
        let encrypted = WebSocketMessage.encrypted(EncryptedWebSocketMessage(payload: EncryptedPayload(
            ciphertext: Data(count: inner.count + 28), senderKeyId: UUID().uuidString
        )))
        #expect(try encoder.encode(encrypted).count < RelayPayloadLimits.maxWebSocketFrameBytes)
    }

    @Test
    func framesRejectInvalidDimensionsAndOversizedPayloads() {
        #expect(RemoteSimulatorFrame(jpeg: Data([1]), width: 1, height: 2_560).isValid)
        #expect(!RemoteSimulatorFrame(jpeg: Data(), width: 1, height: 1).isValid)
        #expect(!RemoteSimulatorFrame(jpeg: Data([1]), width: 0, height: 1).isValid)
        #expect(!RemoteSimulatorFrame(jpeg: Data([1]), width: 2_561, height: 1).isValid)
        #expect(!RemoteSimulatorFrame(jpeg: Data(repeating: 0, count: 512 * 1_024 + 1), width: 1, height: 1).isValid)
    }
}
