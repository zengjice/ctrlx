import Testing
@testable import CtrlxFeature

@Suite("Latest-tap terminal cursor navigation")
struct TerminalCursorNavigationTests {
    private typealias Navigation = TerminalMultilineCursorNavigation
    private typealias Point = Navigation.Point

    @Test("New taps replace the destination while vertical keys are in flight")
    func latestVerticalTarget() {
        var state = TerminalCursorNavigation()
        let lines = draft()
        let origin = Point(column: 4, row: 2)
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 8, row: 1),
                              displayRow: 10, isStable: true) == .vertical(-1))
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 3, row: 3),
                              displayRow: 10, isStable: true) == nil)
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 2, row: 3),
                              displayRow: 10, isStable: true) == nil)
        // Only the newest column/row remains. Do not correct the old column.
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1),
                              displayRow: 10, isStable: true) == .vertical(2))
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 2),
                              displayRow: 10, isStable: true) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 3),
                              displayRow: 10, isStable: true) == nil)
        #expect(!state.isPending)
    }

    @Test("Same-row taps wait for horizontal feedback, including intermediate columns")
    func latestHorizontalTarget() {
        var state = TerminalCursorNavigation()
        let lines = draft()
        let origin = Point(column: 4, row: 1)
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 8, row: 1),
                              displayRow: 0, isStable: true) == .horizontal(4))
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 2, row: 1),
                              displayRow: 0, isStable: true) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 6, row: 1),
                              displayRow: 0, isStable: true) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 8, row: 1),
                              displayRow: 0, isStable: true) == .horizontal(-6))
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1),
                              displayRow: 0, isStable: true) == nil)
        #expect(!state.isPending)
    }

    @Test("A tap arriving during column correction waits for that correction")
    func retargetDuringCorrection() {
        var state = TerminalCursorNavigation()
        let lines = draft()
        #expect(state.request(lines: lines, cursor: .init(column: 4, row: 2), tap: .init(column: 8, row: 1),
                              displayRow: 0, isStable: true) == .vertical(-1))
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1),
                              displayRow: 0, isStable: true) == .horizontal(6))
        #expect(state.request(lines: lines, cursor: .init(column: 2, row: 1), tap: .init(column: 2, row: 3),
                              displayRow: 0, isStable: true) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 8, row: 1),
                              displayRow: 0, isStable: true) == .vertical(2))
    }

    @Test("Body and padding taps cannot replace a valid queued destination", arguments: [0, 4, 5, -1, 99])
    func invalidRetarget(row: Int) {
        var state = TerminalCursorNavigation()
        let lines = draft()
        let origin = Point(column: 4, row: 2)
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 8, row: 1),
                              displayRow: 0, isStable: true) == .vertical(-1))
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 2, row: row),
                              displayRow: 0, isStable: true) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1),
                              displayRow: 0, isStable: true) == .horizontal(6))
    }

    @Test("An initial tap during redraw waits for the real input cursor")
    func deferredInitialTap() {
        var state = TerminalCursorNavigation()
        let lines = draft()
        // A hidden cursor visiting body output is not used as an arrow origin.
        #expect(state.request(lines: lines, cursor: .init(column: 0, row: 0), tap: .init(column: 8, row: 1),
                              displayRow: 0, isStable: false) == nil)
        #expect(state.isPending)
        #expect(state.advance(lines: [], cursor: .init(column: 0, row: 0),
                              displayRow: 0, isStable: false) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 4, row: 2),
                              displayRow: 0, isStable: true) == .vertical(-1))
    }

    @Test("Redraw retargeting uses captured input bounds, not a transient cursor")
    func redrawRetarget() {
        var state = TerminalCursorNavigation()
        let lines = draft()
        #expect(state.request(lines: lines, cursor: .init(column: 4, row: 2), tap: .init(column: 8, row: 1),
                              displayRow: 0, isStable: true) == .vertical(-1))
        #expect(state.request(lines: [], cursor: .init(column: 0, row: 0), tap: .init(column: 2, row: 3),
                              displayRow: 0, isStable: false) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1),
                              displayRow: 0, isStable: true) == .vertical(2))
    }

    @Test("Ambiguous body, padding and unbounded shell rows are not deferred", arguments: [0, 4, 5])
    func noUnboundedDeferral(row: Int) {
        var state = TerminalCursorNavigation()
        #expect(state.request(lines: draft(), cursor: .init(column: 4, row: 2), tap: .init(column: 2, row: row),
                              displayRow: 0, isStable: false) == nil)
        #expect(!state.isPending)
        #expect(state.request(lines: [line("> shell")], cursor: .init(column: 0, row: 0), tap: .init(column: 3, row: 0),
                              displayRow: 0, isStable: false) == nil)
        #expect(!state.isPending)
    }

    @Test("Retargeting cannot prolong a missing feedback timeout", arguments: [false, true])
    func timeout(stable: Bool) {
        var state = TerminalCursorNavigation()
        let now = ContinuousClock.now
        let lines = draft()
        let origin = Point(column: 4, row: 2)
        _ = state.request(lines: lines, cursor: origin, tap: .init(column: 8, row: 1),
                          displayRow: 0, isStable: stable, now: now)
        #expect(state.request(lines: lines, cursor: origin, tap: .init(column: 2, row: 3),
                              displayRow: 0, isStable: false, now: now.advanced(by: .milliseconds(1900))) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1),
                              displayRow: 0, isStable: true, now: now.advanced(by: .seconds(2))) == nil)
        #expect(!state.isPending)
    }

    @Test("Editing, scrolling, resize and cursor escape discard both flight and queued target", arguments: 0..<5)
    func contextChanged(change: Int) {
        var state = TerminalCursorNavigation()
        var lines = draft()
        let origin = Point(column: 4, row: 2)
        _ = state.request(lines: lines, cursor: origin, tap: .init(column: 8, row: 1), displayRow: 0, isStable: true)
        _ = state.request(lines: lines, cursor: origin, tap: .init(column: 2, row: 3), displayRow: 0, isStable: true)
        switch change {
        case 0: lines[2] = line("  edited", shaded: true)
        case 1: lines.append(line(""))
        case 2: lines[1].cells.removeLast()
        default: break
        }
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: change == 4 ? 0 : 1),
                              displayRow: change == 3 ? 1 : 0, isStable: true) == nil)
        #expect(!state.isPending)
    }

    @Test("Cancellation discards a deferred or in-flight destination", arguments: [false, true])
    func cancellation(stable: Bool) {
        var state = TerminalCursorNavigation()
        let lines = draft()
        _ = state.request(lines: lines, cursor: .init(column: 4, row: 2), tap: .init(column: 8, row: 1),
                          displayRow: 0, isStable: stable)
        _ = state.request(lines: lines, cursor: .init(column: 4, row: 2), tap: .init(column: 2, row: 3),
                          displayRow: 0, isStable: stable)
        state.cancel()
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1), displayRow: 0, isStable: true) == nil)
        #expect(!state.isPending)
    }

    @Test("Legacy same-row prompts remain supported without enabling cross-row navigation")
    func legacyPrompt() {
        var state = TerminalCursorNavigation()
        let lines = [line("body"), line("user$ hello")]
        #expect(state.request(lines: lines, cursor: .init(column: 11, row: 1), tap: .init(column: 6, row: 1),
                              displayRow: 0, isStable: true) == .horizontal(-5))
        #expect(state.request(lines: lines, cursor: .init(column: 11, row: 1), tap: .init(column: 2, row: 0),
                              displayRow: 0, isStable: true) == nil)
        #expect(state.advance(lines: lines, cursor: .init(column: 6, row: 1), displayRow: 0, isStable: true) == nil)
        #expect(!state.isPending)
    }

    @Test("Wide-cell targets normalize before awaiting horizontal feedback")
    func wideTarget() {
        var state = TerminalCursorNavigation()
        let lines = [line("› abc", shaded: true), line("  中🙂 end", shaded: true)]
        #expect(state.request(lines: lines, cursor: .init(column: 6, row: 1), tap: .init(column: 3, row: 1),
                              displayRow: 0, isStable: true) == .horizontal(-2))
        #expect(state.advance(lines: lines, cursor: .init(column: 2, row: 1), displayRow: 0, isStable: true) == nil)
        #expect(!state.isPending)
    }

    private func draft() -> [Navigation.Line] {
        [line("body"), line("› first line", shaded: true), line("  second", shaded: true),
         line("  hi", shaded: true), line("", shaded: true), line("footer")]
    }

    private func line(_ text: String, shaded: Bool = false) -> Navigation.Line {
        var cells: [Navigation.Cell] = []
        for character in text {
            let width = "中🙂".contains(character) ? 2 : 1
            cells.append(.init(character: character, width: width, inputBackground: shaded))
            if width == 2 { cells.append(.init(character: "\0", width: 0, inputBackground: shaded)) }
        }
        while cells.count < 16 { cells.append(.init(character: " ", width: 1, inputBackground: shaded)) }
        return .init(cells: cells)
    }
}
