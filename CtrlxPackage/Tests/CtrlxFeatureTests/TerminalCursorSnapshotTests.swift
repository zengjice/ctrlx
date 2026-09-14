#if canImport(SwiftTerm)
    import SwiftTerm
    import Testing
    @testable import CtrlxFeature

    @Suite("Cursor navigation from actual terminal bytes")
    struct TerminalCursorSnapshotTests {
        private typealias Navigation = TerminalMultilineCursorNavigation

        @Test("SGR-painted input and wide cells survive a cursor-only redraw", arguments: [false, true])
        func actualCells(scrollback: Bool) throws {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 24, rows: 8))
            if scrollback {
                for _ in 0..<40 { terminal.feed(text: "history\r\n") }
            }
            terminal.feed(text: "\u{1b}[2J\u{1b}[Hbody")
            for (row, text) in [(2, "› first line"), (3, "  second"), (4, "  中🙂 end"), (5, "")] {
                terminal.feed(text: "\u{1b}[\(row);1H\u{1b}[48;5;236m\u{1b}[2K\(text)")
            }
            terminal.feed(text: "\u{1b}[0m\u{1b}[6;1Hfooter\u{1b}[3;5H")
            #expect((terminal.buffer.yDisp > 0) == scrollback)
            let lines = Navigation.lines(in: terminal)
            #expect(lines.map(\.isShaded) == [false, true, true, true, true, false, false, false])
            #expect(lines.map(\.inputColumn) == [nil, 2, nil, nil, nil, nil, nil, nil])
            let move = try #require(Navigation.PendingMove(
                lines: lines, cursor: .init(column: 4, row: 2),
                tap: .init(column: 6, row: 3), displayRow: terminal.buffer.yDisp
            ))
            #expect(move.region.rows == 1..<4)
            #expect(move.verticalSteps == 1)
            #expect(lines[3].cells[2].character == "中")
            #expect(lines[3].cells[3].width == 0)
            #expect(lines[3].cells[4].character == "🙂")
            terminal.feed(text: "\u{1b}[?25l\u{1b}[4;3H")
            #expect(!terminal.isCursorVisible)
            terminal.feed(text: "\u{1b}[?25h")
            #expect(terminal.isCursorVisible)
            #expect(move.progress(lines: Navigation.lines(in: terminal),
                                  cursor: .init(column: terminal.buffer.x, row: terminal.buffer.y),
                                  displayRow: terminal.buffer.yDisp) == .horizontalSteps(2))
        }

        @Test("Unshaded explicit terminal linefeeds cannot claim output as an editor")
        func plainOutput() {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 24, rows: 8))
            terminal.feed(text: "> first\r\n  output\r\nmore output")
            #expect(Navigation.region(lines: Navigation.lines(in: terminal),
                                      cursor: .init(column: terminal.buffer.x, row: terminal.buffer.y)) == nil)
        }

        @Test("Tap-anchored input survives a redraw cursor in body output", arguments: [false, true])
        func deferredTapSnapshot(wideHalf: Bool) {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 24, rows: 8))
            terminal.feed(text: "\u{1b}[2J\u{1b}[Hbody")
            for (row, text) in [(2, "› first line"), (3, "  中🙂 end")] {
                terminal.feed(text: "\u{1b}[\(row);1H\u{1b}[48;5;236m\u{1b}[2K\(text)")
            }
            terminal.feed(text: "\u{1b}[0m\u{1b}[?2026h\u{1b}[?25l\u{1b}[1;1H")
            let tap = Navigation.Point(column: wideHalf ? 3 : 2, row: 2)
            var state = TerminalCursorNavigation()
            #expect(state.request(lines: Navigation.lines(in: terminal, backgroundAt: tap),
                                  cursor: .init(column: terminal.buffer.x, row: terminal.buffer.y),
                                  tap: tap, displayRow: terminal.buffer.yDisp, isStable: false) == nil)
            #expect(state.isPending)
            terminal.feed(text: "\u{1b}[2;5H\u{1b}[?25h\u{1b}[?2026l")
            #expect(state.advance(lines: Navigation.lines(in: terminal),
                                  cursor: .init(column: terminal.buffer.x, row: terminal.buffer.y),
                                  displayRow: terminal.buffer.yDisp,
                                  isStable: terminal.isCursorVisible && !terminal.synchronizedOutputActive) == .vertical(1))
            terminal.feed(text: "\u{1b}[3;7H")
            #expect(state.advance(lines: Navigation.lines(in: terminal),
                                  cursor: .init(column: terminal.buffer.x, row: terminal.buffer.y),
                                  displayRow: terminal.buffer.yDisp, isStable: true) == .horizontal(-2))
            terminal.feed(text: "\u{1b}[3;3H")
            #expect(state.advance(lines: Navigation.lines(in: terminal),
                                  cursor: .init(column: terminal.buffer.x, row: terminal.buffer.y),
                                  displayRow: terminal.buffer.yDisp, isStable: true) == nil)
            #expect(!state.isPending)
        }

        private final class Delegate: TerminalDelegate {
            func send(source: Terminal, data: ArraySlice<UInt8>) {}
        }
    }
#endif
