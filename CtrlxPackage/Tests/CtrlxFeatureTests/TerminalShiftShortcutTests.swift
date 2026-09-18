#if canImport(SwiftTerm)
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation
    import SwiftTerm
    import Testing

    @Suite("Terminal Shift shortcut transport")
    struct TerminalShiftShortcutTests {
        @Test("Extended keyboard chords use the existing wire format and do not submit input")
        func transport() {
            let chords: [([UInt8], TmuxKey)] = [
                (EscapeSequences.moveLeftShift, .text("\u{1b}[1;2D")),
                (EscapeSequences.moveRightShift, .text("\u{1b}[1;2C")),
                (EscapeSequences.moveUpShift, .text("\u{1b}[1;2A")),
                (EscapeSequences.moveDownShift, .text("\u{1b}[1;2B")),
                (EscapeSequences.cmdBackTab, .backtab),
                (EscapeSequences.cmdShiftRet, .shiftEnter),
            ]
            for (bytes, expected) in chords {
                #expect(TmuxKey.from(bytes: Data(bytes)) == [expected])
                #expect(!TerminalResponseFilter.isTerminalResponse(bytes[...]))
            }
        }
    }
#endif
