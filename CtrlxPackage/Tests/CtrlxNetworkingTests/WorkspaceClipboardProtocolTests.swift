import Crypto
import CtrlxEncryption
import Foundation
import Testing
@testable import CtrlxNetworking

struct WorkspaceClipboardProtocolTests {
    @Test
    func validationAndCompatibility() throws {
        #expect(WorkspaceClipboardContent(text: "中文\nclipboard").isValid)
        #expect(!WorkspaceClipboardContent(text: "").isValid)
        #expect(!WorkspaceClipboardContent(kind: .text, data: Data([0xFF])).isValid)
        #expect(!WorkspaceClipboardContent(kind: .png, data: Data("text".utf8)).isValid)
        #expect(!WorkspaceClipboardContent(text: String(repeating: "a", count: WorkspaceClipboardContent.maximumBytes + 1)).isValid)
        let old = try JSONDecoder().decode(SessionStateMessage.self, from: Data(#"{"pairId":"old","paneStates":{},"homeDirectory":""}"#.utf8))
        #expect(old.supportsWorkspaceClipboard == nil)
        let state = SessionStateMessage(pairId: "a", paneStates: [:], supportsWorkspaceClipboard: true).withPairId("b")
        #expect(state.pairId == "b" && state.supportsWorkspaceClipboard == true)
        let frame = try JSONDecoder().decode(RemoteSimulatorFrame.self, from: Data(#"{"jpeg":"AQ==","width":1,"height":1}"#.utf8))
        #expect(frame.inputGeometry == nil)
    }

    @Test(arguments: [false, true])
    func maximumClipboardFitsEncryptedRequestsAndReplies(slashHeavy: Bool) throws {
        let content: WorkspaceClipboardContent
        if slashHeavy {
            let header = Data([137, 80, 78, 71, 13, 10, 26, 10])
            var low = 0, high = WorkspaceClipboardContent.maximumBytes - header.count
            while low < high {
                let count = (low + high + 1) / 2
                let candidate = WorkspaceClipboardContent(kind: .png, data: header + Data(repeating: 0xFF, count: count))
                if candidate.isValid {
                    low = count
                } else {
                    high = count - 1
                }
            }
            content = .init(kind: .png, data: header + Data(repeating: 0xFF, count: low))
            #expect(!WorkspaceClipboardContent(kind: .png, data: content.data + Data([0xFF])).isValid)
            #expect(try JSONEncoder().encode(content).count > WorkspaceClipboardContent.maximumEncodedBytes - 8)
        } else {
            content = .init(text: String(repeating: "x", count: WorkspaceClipboardContent.maximumBytes))
        }
        #expect(content.isValid)
        let operation = ControlSimulator(sessionName: "work", tabID: UUID(), surfaceID: UUID(), controlID: UUID(), generation: 1, operation: .paste(content))
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(operation.commandType)) == operation.commandType)
        let browser = BrowseBrowser(sessionName: "work", tabID: UUID(), surfaceID: UUID(), controlID: UUID(), operation: .paste(content))
        #expect(try JSONDecoder().decode(CommandType.self, from: JSONEncoder().encode(browser.commandType)) == browser.commandType)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let native: [String: JSONValue] = ["command": .string("clipboard-write"), "content": .object([
            "kind": .string(content.kind.rawValue), "data": .string(content.data.base64EncodedString()),
        ])]
        #expect(try encoder.encode(native).count < 768 * 1_024)
        let messages: [WebSocketMessage] = [
            .command(.init(id: UUID(), paneId: "%1", command: operation.commandType)),
            .command(.init(id: UUID(), paneId: "%1", command: browser.commandType)),
            .commandResponse(.init(commandId: UUID(), success: true, browser: .init(controlID: UUID(), clipboard: content))),
            .commandResponse(.init(commandId: UUID(), success: true, simulatorControl: .init(controlID: UUID(), generation: 1, clipboard: content))),
        ]
        let key = SymmetricKey(size: .bits256)
        for message in messages {
            let inner = try encoder.encode(message)
            let sealed = try ChaChaPoly.seal(inner, using: key)
            let envelope = WebSocketMessage.encrypted(EncryptedWebSocketMessage(payload: EncryptedPayload(
                ciphertext: sealed.combined, senderKeyId: UUID().uuidString,
            )))
            #expect(try encoder.encode(envelope).count < RelayPayloadLimits.maxWebSocketFrameBytes)
            #expect(try ChaChaPoly.open(sealed, using: key) == inner)
        }
    }
}
