import SwiftTerm
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Shared terminal voice context")
struct VoiceInputTerminalContextTests {
    final private class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    @Test("Both clients get the same metadata and soft-wrapped text")
    func wrappedContext() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 12, rows: 5, scrollback: 30))
        let message = "Use VoiceInputController for CtrlX"
        terminal.feed(text: message)
        let text = try #require(VoiceInputContext.recentTerminalText(terminal))
        #expect(text == message)
        let metadata = VoiceInputContext.paneMetadata(
            sessionName: "test", windowName: "code", command: "codex", currentPath: "/tmp/project"
        )
        #expect(metadata == ["Session: test", "Window: code", "Running command: codex", "Current path: /tmp/project"])
        withExtendedLifetime(delegate) { }
    }

    @Test("Context comes from the recent tail, even when the user scrolled to history")
    func tailAfterScrolling() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 60, rows: 5, scrollback: 1_000))
        terminal.feed(text: "oldest\r\n" + String(repeating: "context line\r\n", count: 600) + "newest")
        terminal.buffer.yDisp = 0
        let text = try #require(VoiceInputContext.recentTerminalText(terminal))
        #expect(text.hasSuffix("newest"))
        #expect(!text.contains("oldest"))
        #expect(text.count <= VoiceInputContext.maximumTerminalCharacterCount)
        withExtendedLifetime(delegate) { }
    }

    @Test("Trimmed scrollback and alternate buffers use their own retained rows")
    func trimmedAndAlternateBuffers() throws {
        let delegate = Delegate()
        let terminal = Terminal(delegate: delegate, options: .init(cols: 40, rows: 4, scrollback: 8))
        terminal.feed(text: String(repeating: "history\r\n", count: 100) + "tail")
        #expect(terminal.buffer.totalLinesTrimmed > 0)
        #expect(VoiceInputContext.recentTerminalText(terminal)?.hasSuffix("tail") == true)
        terminal.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[Hagent context")
        let text = try #require(VoiceInputContext.recentTerminalText(terminal))
        #expect(text == "agent context")
        withExtendedLifetime(delegate) { }
    }

    @Test("Speech output cannot inject Enter or control keys into terminal input")
    func terminalSafeText() {
        let text = VoiceInputTextComposer.terminalTranscript(" one\r\ntwo\tthree\u{1B}\u{7F} ")
        #expect(text == "one two three")
        #expect(VoiceInputTextComposer.terminalTranscript("开发者 👩‍💻") == "开发者 👩‍💻")
        #expect(VoiceTranscriptCorrectionPolicy.accepted("wrong\tcommand", replacing: "safe") == "safe")
        #expect(VoiceTranscriptCorrectionPolicy.accepted("开发者 👩‍💻", replacing: "开发者") == "开发者 👩‍💻")
    }
}
