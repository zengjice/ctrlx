import SwiftTerm
import Testing
@testable import CtrlxCommon

@MainActor
struct CodexQuestionTerminalTests {
    final private class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) { }
    }

    private func drawPrompt(_ terminal: Terminal) {
        // Cursor movement leaves unwritten cells between words, as a TUI
        // incremental repaint can. They display identically to printed spaces.
        terminal.feed(text: "\u{1B}[2J\u{1B}[2;3H•\u{1B}[1CQueued\u{1B}[1Cfollow-up\u{1B}[1Cinputs")
        terminal.feed(text: "\u{1B}[3;3H?\u{1B}[1C1\u{1B}[1Cquestion\u{1B}[1C·\u{1B}[1C19s")
        terminal.feed(text: "\u{1B}[4;5H⇧←\u{1B}[1Cto\u{1B}[1Canswer")
        terminal.feed(text: "\u{1B}[7;1H›\u{1B}[1CAsk Codex to do anything\u{1B}[7;3H")
    }

    @Test("Terminal blank cells are spaces in the composer and Questions footer", arguments: [false, true])
    func unwrittenCells(warning: Bool) throws {
        let delegate = Delegate()
        defer { withExtendedLifetime(delegate) { } }
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 12))
        drawPrompt(terminal)
        if warning {
            terminal.feed(text: "\u{1B}[5;30H⚠\u{1B}[1Cweekly limit: 8% left · /status\u{1B}[7;3H")
        }
        let composer = try #require(terminal.getLine(row: 6))
        let before = composer.translateToString(trimRight: true)
        #expect(before.contains("\0"))
        #expect(try CodexQuestionPrompt(terminal: terminal).count == 1)
        #expect(composer.translateToString(trimRight: true) == before)
        #expect(terminal.buffer.x == 2 && terminal.buffer.y == 6)
    }

    @Test("Blank-cell conversion preserves drafts and does not join text fragments", arguments: [
        "draft", "你好", "🧑‍💻", "As\u{1B}[1Ck Codex to do anything", "Ask Codex to do anything draft",
    ])
    func drafts(text: String) {
        let delegate = Delegate()
        defer { withExtendedLifetime(delegate) { } }
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 12))
        drawPrompt(terminal)
        terminal.feed(text: "\u{1B}[7;1H\u{1B}[2K›\u{1B}[1C\(text)\u{1B}[7;3H")
        #expect(throws: CodexQuestionPrompt.RecognitionError.unrecognizedComposer) {
            try CodexQuestionPrompt(terminal: terminal)
        }
    }

    @Test("Incomplete or unknown footers remain manual after blank-cell conversion", arguments: [
        "⇧←", "⇧→ to answer", "⇧← to answer extra", "⇧← to answer\r\nunknown warning",
    ])
    func incompleteFooter(hint: String) {
        let delegate = Delegate()
        defer { withExtendedLifetime(delegate) { } }
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 12))
        drawPrompt(terminal)
        terminal.feed(text: "\u{1B}[4;1H\u{1B}[2K\(hint)\u{1B}[7;3H")
        #expect(throws: CodexQuestionPrompt.RecognitionError.unrecognizedFooter) {
            try CodexQuestionPrompt(terminal: terminal)
        }
    }

    @Test("The cursor must still be at the empty composer's input start")
    func cursorGuard() {
        let delegate = Delegate()
        defer { withExtendedLifetime(delegate) { } }
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 12))
        drawPrompt(terminal)
        terminal.feed(text: "\u{1B}[7;4H")
        #expect(throws: CodexQuestionPrompt.RecognitionError.cursorNotAtStart) {
            try CodexQuestionPrompt(terminal: terminal)
        }
    }

    @Test("An empty queue can reset after an incremental repaint with blank cells")
    func emptyQueue() throws {
        let delegate = Delegate()
        defer { withExtendedLifetime(delegate) { } }
        let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 12))
        drawPrompt(terminal)
        #expect(try CodexQuestionPrompt(terminal: terminal).count == 1)
        terminal.feed(text: "\u{1B}[2;1H\u{1B}[2K\u{1B}[3;1H\u{1B}[2K\u{1B}[4;1H\u{1B}[2K\u{1B}[7;3H")
        let count = try CodexQuestionPrompt(terminal: terminal).count
        #expect(count == 0)
    }

    @Test("An invalid cursor row has a distinct diagnostic")
    func invalidRow() {
        #expect(throws: CodexQuestionPrompt.RecognitionError.cursorOutsideScreen) {
            try CodexQuestionPrompt(validating: [], cursorRow: 0, cursorColumn: 2)
        }
    }
}
