#if os(macOS)
    import SwiftTerm
    import Testing
    @testable import CtrlxFeature

    @MainActor
    @Suite("Terminal text snapshot")
    struct TerminalTextSnapshotTests {
        @Test("Empty terminal does not create a snapshot")
        func emptyTerminal() {
            let (terminal, _) = makeTerminal(cols: 20, rows: 3)

            #expect(TerminalTextSnapshot(terminal: terminal) == nil)
        }

        @Test("Snapshot includes text and removes terminal padding")
        func textAndPadding() throws {
            let (terminal, _) = makeTerminal(cols: 20, rows: 4)
            terminal.feed(text: "first\r\n  second  ")

            let snapshot = try #require(TerminalTextSnapshot(terminal: terminal))
            #expect(snapshot.text == "first\n  second  ")
        }

        @Test("Snapshot includes retained scrollback")
        func scrollback() throws {
            let (terminal, _) = makeTerminal(cols: 20, rows: 2)
            terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour")

            let snapshot = try #require(TerminalTextSnapshot(terminal: terminal))
            #expect(snapshot.text.contains("one"))
            #expect(snapshot.text.contains("four"))
        }

        @Test("Snapshot joins terminal-width soft wraps")
        func softWraps() throws {
            let (terminal, _) = makeTerminal(cols: 5, rows: 3)
            terminal.feed(text: "abcdefgh")

            let snapshot = try #require(TerminalTextSnapshot(terminal: terminal))
            #expect(snapshot.text == "abcdefgh")
        }

        @Test("Snapshot preserves hard line breaks and blank lines")
        func hardBreaksAndBlankLines() throws {
            let (terminal, _) = makeTerminal(cols: 20, rows: 5)
            terminal.feed(text: "one\r\n\r\nthree")

            let snapshot = try #require(TerminalTextSnapshot(terminal: terminal))
            #expect(snapshot.text == "one\n\nthree")
        }

        @Test("Snapshot reads the active alternate buffer")
        func alternateBuffer() throws {
            let (terminal, _) = makeTerminal(cols: 20, rows: 3)
            terminal.feed(text: "normal")
            terminal.feed(text: "\u{1B}[?1049h")
            terminal.feed(text: "alternate")

            let snapshot = try #require(TerminalTextSnapshot(terminal: terminal))
            #expect(snapshot.text.contains("alternate"))
            #expect(!snapshot.text.contains("normal"))
        }

        @Test("Snapshot preserves Unicode and remains immutable")
        func unicodeAndImmutability() throws {
            let (terminal, _) = makeTerminal(cols: 40, rows: 3)
            terminal.feed(text: "你好 CtrlX")
            let snapshot = try #require(TerminalTextSnapshot(terminal: terminal))

            terminal.feed(text: " updated")

            #expect(snapshot.text == "你好 CtrlX")
            #expect(!snapshot.text.contains("\0"))
            #expect(TerminalTextSnapshot(terminal: terminal)?.text == "你好 CtrlX updated")
        }

        private func makeTerminal(cols: Int, rows: Int) -> (Terminal, TestTerminalDelegate) {
            let delegate = TestTerminalDelegate()
            let terminal = Terminal(delegate: delegate)
            terminal.resize(cols: cols, rows: rows)
            return (terminal, delegate)
        }
    }

    final private class TestTerminalDelegate: TerminalDelegate {
        func send(source _: Terminal, data _: ArraySlice<UInt8>) { }
        func showCursor(source _: Terminal) { }
        func hideCursor(source _: Terminal) { }
        func setTerminalTitle(source _: Terminal, title _: String) { }
        func setTerminalIconTitle(source _: Terminal, title _: String) { }
        func sizeChanged(source _: Terminal) { }
        func scrolled(source _: Terminal, yDisp _: Int) { }
        func hostCurrentDirectoryUpdated(source _: Terminal) { }
        func hostCurrentDocumentUpdated(source _: Terminal) { }
    }
#endif
