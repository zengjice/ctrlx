import Foundation
import Testing
@testable import CtrlxNetworking

@Suite("Terminal clipboard paste wire format")
struct TerminalPasteCommandTests {
    @Test("Old Host snapshots omit terminal capabilities; copies preserve explicit offers")
    func hostCapabilities() throws {
        let legacy = SessionStateMessage(pairId: "old", paneStates: [:])
        let oldJSON = try JSONEncoder().encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: oldJSON) as? [String: Any])
        #expect(object["supportsAgentFork"] == nil)
        #expect(object["supportsTerminalPaste"] == nil)
        #expect(object["supportsTerminalFit"] == nil)
        let decoded = try JSONDecoder().decode(SessionStateMessage.self, from: oldJSON)
        #expect(decoded.supportsAgentFork != true)
        #expect(decoded.supportsTerminalPaste != true)
        #expect(decoded.supportsTerminalFit != true)
        let modern = SessionStateMessage(pairId: "", paneStates: [:], supportsAgentFork: true, supportsTerminalPaste: true, supportsTerminalFit: true)
        let copied = try JSONDecoder().decode(SessionStateMessage.self, from: JSONEncoder().encode(modern.withPairId("new")))
        #expect(copied.pairId == "new")
        #expect(copied.supportsAgentFork == true)
        #expect(copied.supportsTerminalPaste == true)
        #expect(copied.supportsTerminalFit == true)
    }

    @Test("Paste stays one operation and preserves Unicode, CRLF, LF, and trailing newlines")
    func roundTrip() throws {
        let text = "第一行 🙂\r\nsecond\n\nlast\r\n"
        let command = CommandMessage(paneId: "%5", command: PasteTerminalText(text: text).commandType)
        let decoded = try JSONDecoder().decode(CommandMessage.self, from: JSONEncoder().encode(command))
        #expect(decoded.id == command.id)
        #expect(decoded.paneId == "%5")
        #expect(decoded.command == command.command)
        #expect(decoded.command.requiresResponse)
        guard case let .pasteTerminalText(paste) = decoded.command else {
            Issue.record("Paste was converted into keystrokes")
            return
        }
        #expect(Array(paste.text.utf8) == Array(text.utf8))
    }

    @Test("Worst-case clipboard JSON fits the encrypted relay frame budget")
    func boundedPayload() throws {
        let command = CommandMessage(
            paneId: "%5",
            command: PasteTerminalText(text: String(repeating: "\u{01}", count: PasteTerminalText.maximumUTF8Bytes)).commandType
        )
        let json = try JSONEncoder().encode(WebSocketMessage.command(command))
        // AES-GCM overhead, Base64 expansion and encrypted-envelope metadata.
        #expect(((json.count + 28 + 2) / 3) * 4 + 1_024 < RelayPayloadLimits.maxWebSocketFrameBytes)
    }
}
