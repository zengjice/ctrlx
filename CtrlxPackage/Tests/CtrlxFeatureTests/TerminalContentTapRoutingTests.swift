import Testing
@testable import CtrlxFeature

@Suite("Terminal single-tap ownership")
struct TerminalContentTapRoutingTests {
    @Test("Selection, links and input gates precede keyboard toggling and remote input", arguments: 0..<64)
    func routing(combination: Int) {
        let selected = combination & 1 != 0
        let link = combination & 2 != 0
        let enabled = combination & 4 != 0
        let mouse = combination & 8 != 0
        let live = combination & 16 != 0
        let empty = combination & 32 != 0
        let action = TerminalContentTapRouting.action(
            selectionActive: selected, hasLink: link, canSendInput: enabled,
            mouseModeActive: mouse, isLiveScreen: live, isEmptyInputArea: empty
        )
        if selected {
            #expect(action == .ignore)
        } else if link {
            #expect(action == .openLink)
        } else if !enabled || !live {
            #expect(action == .ignore)
        } else if empty {
            #expect(action == .toggleKeyboard)
        } else {
            #expect(action == (mouse ? .mouseClick : .cursorNavigation))
        }
    }

    @Test("An empty prompt and Codex placeholder toggle, but real or unknown text does not", arguments: [false, true])
    func emptyPrompt(mouse: Bool) {
        for text in ["› ", "› Ask Codex to do anything", "> ", "❯ "] {
            #expect(isEmpty([line(text)], cursorColumn: 2, mouse: mouse))
        }
        for text in ["› draft", "› 未发送的内容", "› other placeholder", "› Ask Codex to do anything else"] {
            #expect(!isEmpty([line(text)], cursorColumn: 2, mouse: mouse))
        }
        #expect(!isEmpty([line("› draft")], cursorColumn: 7, mouse: mouse))
        #expect(!isEmpty([line("› draft > ")], cursorColumn: 10, mouse: mouse))
        #expect(!isEmpty([line("")], cursorColumn: 0, mouse: mouse))
        #expect(isEmpty([line("user@host % ")], cursorColumn: 12, mouse: false))
        #expect(!isEmpty([line("selected item")], cursorColumn: 2, mouse: true))
    }

    @Test("Empty shaded padding toggles; output, footer and multiline drafts keep their actions")
    func boxedInput() {
        let empty = [line("", shaded: true), line("› Ask Codex to do anything", shaded: true), line("", shaded: true), line("footer")]
        for row in 0...2 {
            #expect(TerminalContentTapRouting.isEmptyInputArea(
                lines: empty, cursor: .init(column: 2, row: 1), tap: .init(column: 15, row: row), mouseModeActive: true
            ))
        }
        #expect(!TerminalContentTapRouting.isEmptyInputArea(
            lines: empty, cursor: .init(column: 2, row: 1), tap: .init(column: 15, row: 3), mouseModeActive: true
        ))
        let multiline = [line("› ", shaded: true), line("  draft on next line", shaded: true)]
        #expect(!isEmpty(multiline, cursorColumn: 2, mouse: true))
        #expect(!TerminalContentTapRouting.isEmptyInputArea(
            lines: [line("› draft", shaded: true), line("", shaded: true)],
            cursor: .init(column: 0, row: 1), tap: .init(column: 15, row: 1), mouseModeActive: false
        ))
    }

    private func isEmpty(_ lines: [TerminalMultilineCursorNavigation.Line], cursorColumn: Int, mouse: Bool) -> Bool {
        TerminalContentTapRouting.isEmptyInputArea(
            lines: lines, cursor: .init(column: cursorColumn, row: 0), tap: .init(column: 20, row: 0), mouseModeActive: mouse
        )
    }

    @Test("Keyboard reopening recognizes multiline drafts but excludes output and TUI menus", arguments: [false, true])
    func draftInputArea(mouse: Bool) {
        let lines = [line("output"), line("› first", shaded: true), line("  second", shaded: true), line("footer")]
        for row in lines.indices {
            #expect(TerminalContentTapRouting.isInputArea(
                lines: lines, cursor: .init(column: 4, row: 2), tap: .init(column: 3, row: row), mouseModeActive: mouse
            ) == (row == 1 || row == 2))
        }
        #expect(!TerminalContentTapRouting.isInputArea(
            lines: [line("selected menu item")], cursor: .init(column: 5, row: 0),
            tap: .init(column: 3, row: 0), mouseModeActive: true
        ))
    }

    private func line(_ text: String, shaded: Bool = false) -> TerminalMultilineCursorNavigation.Line {
        let characters = Array(text.padding(toLength: 60, withPad: " ", startingAt: 0))
        return .init(cells: characters.map { .init(character: $0, width: 1, inputBackground: shaded) })
    }
}

#if canImport(SwiftTerm)
    import SwiftTerm

    @Suite("Native terminal mouse click encoding")
    struct TerminalMouseClickTests {
        @Test("Normal/button/any tracking sends exactly one left press and release", arguments: [1000, 1002, 1003])
        func sgrClick(mode: Int) {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            terminal.feed(text: "\u{1b}[?\(mode)h\u{1b}[?1006h")
            #expect(click(terminal))
            #expect(delegate.writes == bytes("\u{1b}[<0;6;4M", "\u{1b}[<0;6;4m"))
            terminal.feed(text: "\u{1b}[?\(mode)l")
            delegate.writes = []
            #expect(!click(terminal))
            #expect(delegate.writes.isEmpty)
        }

        @Test("Alternate screen and a hidden redraw cursor do not disable native click")
        func alternateScreen() {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            terminal.feed(text: "\u{1b}[?1049h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?25l\u{1b}[?2026h")
            #expect(click(terminal))
            #expect(delegate.writes == bytes("\u{1b}[<0;6;4M", "\u{1b}[<0;6;4m"))
        }

        @Test("Live screen coordinates subtract scrollback; history never emits a click")
        func scrollbackCoordinates() {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            for _ in 0..<60 { terminal.feed(text: "history\r\n") }
            terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
            let liveRow = terminal.buffer.yDisp
            #expect(liveRow > 0)
            #expect(click(terminal, absoluteRow: liveRow + 3, liveRow: liveRow))
            #expect(delegate.writes == bytes("\u{1b}[<0;6;4M", "\u{1b}[<0;6;4m"))
            delegate.writes = []
            #expect(!click(terminal, absoluteRow: liveRow - 1, liveRow: liveRow))
            terminal.buffer.yDisp = liveRow - 1
            #expect(!click(terminal, absoluteRow: liveRow + 3, liveRow: liveRow))
            #expect(delegate.writes.isEmpty)
        }

        @Test("Out-of-grid taps cannot be clamped onto another control", arguments: [(-1, 0), (80, 0), (0, -1), (0, 24)])
        func bounds(point: (Int, Int)) {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1006h")
            #expect(!click(terminal, column: point.0, absoluteRow: point.1))
            #expect(delegate.writes.isEmpty)
        }

        @Test("Classic tracking is encoded by SwiftTerm, not forced to SGR")
        func classicProtocol() {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            terminal.feed(text: "\u{1b}[?1000h")
            #expect(click(terminal))
            #expect(delegate.writes == [[27, 91, 77, 32, 38, 36], [27, 91, 77, 35, 38, 36]])
        }

        @Test("Legacy X10 tracking requests press only")
        func x10PressOnly() {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            terminal.feed(text: "\u{1b}[?9h")
            #expect(click(terminal))
            #expect(delegate.writes == [[27, 91, 77, 32, 38, 36]])
        }

        @Test("Pixel reporting uses terminal-local pixels instead of cell indices")
        func pixelProtocol() {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 24))
            terminal.feed(text: "\u{1b}[?1003h\u{1b}[?1016h")
            #expect(click(terminal))
            #expect(delegate.writes == bytes("\u{1b}[<0;45;63M", "\u{1b}[<0;45;63m"))
        }

        private func click(_ terminal: Terminal, column: Int = 5, absoluteRow: Int = 3, liveRow: Int = 0) -> Bool {
            TerminalContentTapRouting.reportMouseClick(
                terminal: terminal, column: column, absoluteRow: absoluteRow,
                liveDisplayRow: liveRow, pixelX: 45, pixelY: 63
            )
        }

        private func bytes(_ strings: String...) -> [[UInt8]] { strings.map { Array($0.utf8) } }

        private final class Delegate: TerminalDelegate {
            var writes: [[UInt8]] = []
            func send(source: Terminal, data: ArraySlice<UInt8>) { writes.append(Array(data)) }
        }
    }
#endif
