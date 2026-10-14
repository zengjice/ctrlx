import Testing
@testable import CtrlxFeature

@Suite("Terminal cursor tap navigation")
struct TerminalCursorTapNavigationTests {
    @Test("The focused live cursor row is reserved for input")
    func liveInputRow() {
        #expect(isInputRow(tappedRow: 109))
    }

    @Test("Other rows retain selection, even adjacent draft or footer rows", arguments: [0, 99, 100, 108, 110, 119])
    func otherRows(tappedRow: Int) {
        #expect(!isInputRow(tappedRow: tappedRow))
    }

    @Test("Inactive panes and an unfocused input proxy retain selection")
    func inputGates() {
        #expect(!isInputRow(inputEnabled: false))
        #expect(!isInputRow(inputFocused: false))
    }

    @Test("Mouse-mode TUIs retain their original local selection behavior")
    func mouseMode() {
        #expect(!isInputRow(mouseModeActive: true))
    }

    @Test("History must not be mistaken for a live input row")
    func history() {
        // Even if the tapped row equals the cursor-relative row in a scrolled
        // viewport, it is not the live screen and must remain selectable.
        #expect(!isInputRow(displayRow: 90, tappedRow: 99))
    }

    @Test("Zero-distance cursor taps still belong to the input row")
    func cursorDoesNotNeedToMove() {
        #expect(isInputRow())
        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 0,
            tappedColumn: 0,
            cellWidths: [1, 1, 1]
        ) == 0)
    }

    @Test("Moves left and right by logical character count")
    func directions() {
        let widths = [1, 1, 1, 1, 1]

        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 4,
            tappedColumn: 1,
            cellWidths: widths
        ) == -3)
        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 1,
            tappedColumn: 4,
            cellWidths: widths
        ) == 3)
        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 2,
            tappedColumn: 2,
            cellWidths: widths
        ) == 0)
    }

    @Test("Wide glyph trailing cells do not emit extra arrow keys")
    func wideGlyphs() {
        // A, 中 (two terminal cells), B
        let widths = [1, 2, 0, 1]

        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 4,
            tappedColumn: 1,
            cellWidths: widths
        ) == -2)
        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 0,
            tappedColumn: 3,
            cellWidths: widths
        ) == 2)
    }

    @Test("Out-of-range terminal columns are clamped")
    func clampsColumns() {
        let widths = [1, 2, 0, 1]

        #expect(TerminalCursorTapNavigation.signedStepCount(
            cursorColumn: 99,
            tappedColumn: -1,
            cellWidths: widths
        ) == -3)
    }

    private func isInputRow(
        inputEnabled: Bool = true,
        inputFocused: Bool = true,
        mouseModeActive: Bool = false,
        displayRow: Int = 100,
        tappedRow: Int = 109
    ) -> Bool {
        TerminalCursorTapNavigation.isInputRow(
            inputEnabled: inputEnabled,
            inputFocused: inputFocused,
            mouseModeActive: mouseModeActive,
            displayRow: displayRow,
            liveDisplayRow: 100,
            cursorRow: displayRow + 9,
            tappedRow: tappedRow
        )
    }
}
