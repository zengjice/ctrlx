import Testing
@testable import CtrlxFeature

@Suite("Codex asynchronous question answer hit testing")
struct CodexAsyncQuestionInputAreaTests {
    typealias Navigation = TerminalMultilineCursorNavigation

    /// Captured from the expanded Codex 0.165.0 asynchronous question.
    private let freeform = [
        "", "  Share details.", "  The question can wrap.", "",
        "  Type your answer", "", "  enter submit   ⌃] skip   ⇧→ main prompt", "",
    ]

    @Test("Promptless answer and padding are input; prose and footer are not")
    func freeformBounds() {
        let lines = freeform.map(line)
        for row in lines.indices {
            #expect(contains(lines, cursor: .init(column: 2, row: 4), row: row) == (3...5).contains(row))
        }
        for column in [-1, 0, 1, 67, 68, 69] {
            #expect(!contains(lines, cursor: .init(column: 2, row: 4), row: 4, column: column))
        }
    }

    @Test("Empty drafts and multiline continuations keep the answer bounds", arguments: ["", "Type your answer", "first line"])
    func multiline(draft: String) {
        var rows = freeform
        rows.insert("", at: 6)
        rows[4] = "  " + draft
        rows[5] = "  continuation"
        let lines = rows.map(line)
        for cursor in [Navigation.Point(column: 2, row: 4), .init(column: 8, row: 5)] {
            for row in 3...6 {
                #expect(contains(lines, cursor: cursor, row: row))
            }
        }
    }

    @Test("Inline custom answers exclude preceding choices and their wrapped labels")
    func customAnswer() {
        let rows = [
            "", "  Pick an option.", "", "    1. First option", "       wrapped option",
            "    2. Second option", "  › 3. Type another answer", "       continuation", "",
            "  enter submit   ⌃] skip   ⇧→ prev question   ⇧← next question", "",
        ]
        var lines = rows.map(line)
        lines[3].cells[20].inputBackground = false
        for cursor in [Navigation.Point(column: 7, row: 6), .init(column: 12, row: 7)] {
            for row in rows.indices {
                #expect(contains(lines, cursor: cursor, row: row) == (6...8).contains(row))
            }
        }
    }

    @Test("Wrapped navigation hints and remapped submit keys are recognized")
    func footer() {
        var rows = freeform
        rows[6] = "  ctrl+s submit   ⌃] skip"
        rows[7] = "  ⇧→ prev question   ⇧← next question"
        let lines = rows.map(line)
        #expect(contains(lines, cursor: .init(column: 2, row: 4), row: 5))
        #expect(!contains(lines, cursor: .init(column: 2, row: 4), row: 6))
        #expect(!contains(lines, cursor: .init(column: 2, row: 4), row: 7))
    }

    @Test("An answer containing footer-like text does not truncate the input")
    func footerTextInsideDraft() {
        var rows = freeform
        rows[4] = "  first line"
        rows.insert("  enter submit", at: 5)
        rows.insert("  still part of the answer", at: 6)
        let lines = rows.map(line)
        for row in 3...7 {
            #expect(contains(lines, cursor: .init(column: 4, row: 4), row: row))
        }
    }

    @Test("Unknown menus, missing hints, broken surfaces and invalid cursors fail closed")
    func guards() {
        for footer in ["  enter submit", "  enter submit   ⌃] skip", "  enter submit   ⇧→ main prompt", "  enter to submit answer | esc to interrupt"] {
            var rows = freeform
            rows[6] = footer
            #expect(!contains(rows.map(line), cursor: .init(column: 2, row: 4), row: 4))
        }
        let lines = freeform.map(line)
        for cursor in [Navigation.Point(column: 1, row: 4), .init(column: 68, row: 4), .init(column: 2, row: 1), .init(column: 2, row: 6)] {
            #expect(!contains(lines, cursor: cursor, row: 4))
        }
        for row in 3...5 {
            var broken = lines
            broken[row].cells[30].inputBackground = false
            #expect(!contains(broken, cursor: .init(column: 2, row: 4), row: row))
        }
        var broken = lines
        broken[5].cells[0].character = "x"
        #expect(!contains(broken, cursor: .init(column: 2, row: 4), row: 5))
        #expect(!contains(Array(lines.prefix(6)), cursor: .init(column: 2, row: 4), row: 4))
    }

    private func contains(_ lines: [Navigation.Line], cursor: Navigation.Point, row: Int, column: Int = 20) -> Bool {
        CodexQuestionInputArea.contains(lines: lines, cursor: cursor, tap: .init(column: column, row: row))
    }

    private func line(_ text: String) -> Navigation.Line {
        .init(cells: Array(text.padding(toLength: 69, withPad: " ", startingAt: 0)).map {
            .init(character: $0, width: 1, inputBackground: true)
        })
    }
}

#if canImport(SwiftTerm)
    import SwiftTerm

    @Suite("Codex asynchronous question ANSI replay")
    struct CodexAsyncQuestionInputANSITests {
        @Test("Captured promptless layout recognizes the cursor row and padding", arguments: ["48;2;57;57;57", "48;2;230;230;230"])
        func capturedFreeform(background: String) {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 69, rows: 12))
            let surface = "\u{1b}[0;\(background)m"
            let rows = [
                "", "  \u{1b}[38;2;99;168;248m键盘复现：请点击输入区测试键盘。\u{1b}[39m",
                "  暂时保留问题展开状态，不用提交答案。", "", "  \u{1b}[2mType your answer",
                "", "  \u{1b}[1menter\u{1b}[22m submit   ⌃] skip   ⇧→ main prompt", "",
            ]
            for (row, text) in rows.enumerated() {
                terminal.feed(text: "\u{1b}[\(row + 1);1H" + surface + "\u{1b}[2K" + text)
            }
            terminal.feed(text: surface + "\u{1b}[5;3H")
            let lines = TerminalMultilineCursorNavigation.lines(in: terminal)
            for row in rows.indices {
                #expect(CodexQuestionInputArea.contains(lines: lines, cursor: .init(column: 2, row: 4), tap: .init(column: 20, row: row)) == (3...5).contains(row))
            }
        }

        final private class Delegate: TerminalDelegate {
            func send(source _: Terminal, data _: ArraySlice<UInt8>) { }
        }
    }
#endif
