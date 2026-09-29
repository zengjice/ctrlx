import Testing
@testable import CtrlxFeature

@Suite("Terminal single-tap ownership")
struct TerminalContentTapRoutingTests {
    @Test("Selection, links and input gates precede both input routes", arguments: 0..<32)
    func routing(combination: Int) {
        let selected = combination & 1 != 0
        let link = combination & 2 != 0
        let enabled = combination & 4 != 0
        let mouse = combination & 8 != 0
        let live = combination & 16 != 0
        let action = TerminalContentTapRouting.action(
            selectionActive: selected, hasLink: link, canSendInput: enabled,
            mouseModeActive: mouse, isLiveScreen: live
        )
        if selected {
            #expect(action == .ignore)
        } else if link {
            #expect(action == .openLink)
        } else if !enabled || !live {
            #expect(action == .ignore)
        } else {
            #expect(action == (mouse ? .mouseClick : .cursorNavigation))
        }
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
