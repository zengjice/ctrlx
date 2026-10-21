import Testing
@testable import CtrlxFeature

@Suite("Codex Questions answer hit testing")
struct CodexQuestionInputAreaTests {
    typealias Navigation = TerminalMultilineCursorNavigation

    /// Text layout from Codex 0.162.1 request_user_input snapshots.
    /// Selection styles are exercised separately through SwiftTerm ANSI replay.
    private let freeform = [
        "", "  Question 1/1 (1 unanswered)", "  Share details.", "",
        "  › Type your answer (optional)", "", "",
        "  enter to submit answer | esc to interrupt", "",
    ]
    private let notes = [
        "", "  Question 1/2 (2 unanswered)", "  Choose an option.", "",
        "  › 1. Option 1", "    2. Option 2", "",
        "  › Add notes", "", "",
        "  tab or esc to clear notes | enter to submit answer", "",
    ]

    @Test("Freeform placeholder and its padding are input; question and footer are not")
    func freeformBounds() {
        let lines = freeform.map(line)
        for row in lines.indices {
            #expect(contains(lines, cursor: .init(column: 4, row: 4), row: row) == (3...6).contains(row))
        }
        for column in [-1, 0, 1, 58, 59, 60] {
            #expect(!contains(lines, cursor: .init(column: 4, row: 4), row: 4, column: column))
        }
    }

    @Test("Notes composer is separate from the option list despite matching prompts and background")
    func notesBounds() {
        let lines = notes.map(line)
        for row in lines.indices {
            #expect(contains(lines, cursor: .init(column: 4, row: 7), row: row) == (6...9).contains(row))
        }
    }

    @Test("Empty and wrapped answers work with the cursor at any draft row", arguments: ["", "first line"])
    func multiline(first: String) {
        var rows = freeform
        rows[4] = "  › " + first
        rows[5] = "    continuation"
        let lines = rows.map(line)
        for cursor in [Navigation.Point(column: 4, row: 4), .init(column: 10, row: 5)] {
            for row in 3...6 {
                #expect(contains(lines, cursor: cursor, row: row))
            }
        }
    }

    @Test("Wrapped footer and remapped submit key remain outside the answer")
    func footer() {
        var rows = notes
        rows[1] = "  Question 2/2 (1 unanswered) · auto-resolves in 30s"
        rows[10] = "  tab or esc to clear notes"
        rows[11] = "  ctrl+s to submit all"
        let lines = rows.map(line)
        #expect(contains(lines, cursor: .init(column: 4, row: 7), row: 9))
        #expect(!contains(lines, cursor: .init(column: 4, row: 7), row: 10))
        #expect(!contains(lines, cursor: .init(column: 4, row: 7), row: 11))
    }

    @Test("A closed notes editor and other menus cannot turn into answer regions")
    func menus() {
        let options = Array(notes.prefix(6)) + ["", "  tab to add notes | enter to submit answer | esc to interrupt", ""]
        #expect(!contains(options.map(line), cursor: .init(column: 4, row: 4), row: 6))
        for header in ["Select a model", "Question 0/1", "Question 2/1", "Question 1", "Queued follow-up inputs"] {
            var rows = freeform
            rows[1] = header
            #expect(!contains(rows.map(line), cursor: .init(column: 4, row: 4), row: 4))
        }
    }

    @Test("Truncated/redrawing surfaces and a cursor outside the composer fail closed")
    func incomplete() {
        let lines = freeform.map(line)
        #expect(!contains(Array(lines.prefix(7)), cursor: .init(column: 4, row: 4), row: 5))
        for cursor in [Navigation.Point(column: 4, row: 2), .init(column: 2, row: 4), .init(column: 4, row: 7), .init(column: 80, row: 4)] {
            #expect(!contains(lines, cursor: cursor, row: 4))
        }
        var broken = lines
        broken[5] = line("  other content")
        #expect(!contains(broken, cursor: .init(column: 4, row: 4), row: 5))
        broken = lines
        broken[3].cells = broken[3].cells.map {
            var cell = $0
            cell.inputBackground = false
            return cell
        }
        #expect(!contains(broken, cursor: .init(column: 4, row: 4), row: 5))
        #expect(!contains(lines, cursor: .init(column: 4, row: 4), row: -1))
        #expect(!contains(lines, cursor: .init(column: 4, row: 4), row: lines.count))
    }

    private func contains(_ lines: [Navigation.Line], cursor: Navigation.Point, row: Int, column: Int = 20) -> Bool {
        CodexQuestionInputArea.contains(lines: lines, cursor: cursor, tap: .init(column: column, row: row))
    }

    private func line(_ text: String) -> Navigation.Line {
        .init(cells: Array(text.padding(toLength: 60, withPad: " ", startingAt: 0)).map {
            .init(character: $0, width: 1, inputBackground: true)
        })
    }
}

#if canImport(SwiftTerm)
    import SwiftTerm

    @Suite("Codex Questions ANSI selection styles")
    struct CodexQuestionInputANSITests {
        @Test("Selected options do not block notes padding or wrapped answers", arguments: [false, true], [false, true])
        func notesSelection(inverse: Bool, wrapped: Bool) {
            let delegate = Delegate()
            let terminal = Terminal(delegate: delegate, options: .init(cols: 80, rows: 20))
            let surface = "\u{1b}[0;48;5;236m"
            let selection = inverse ? "\u{1b}[0;7m" : "\u{1b}[38;2;20;30;40;48;2;190;210;255m"
            let rows = [
                "", "  Question 1/2 (2 unanswered)", "  Choose an option.", "",
                "  › 1. Selected option", "       wrapped option description", "    2. Another option", "",
                wrapped ? "  › first line" : "  › Add notes",
                wrapped ? "    continuation" : "", "",
                "  tab or esc to clear notes | enter to submit answer", "",
            ]
            var ansi = "\u{1b}[2J"
            for (row, text) in rows.enumerated() {
                ansi += "\u{1b}[\(row + 1);1H" + surface
                if row == 4 || row == 5 {
                    // Codex keeps two surface columns on either side of selected rows.
                    ansi += "  " + selection + String(text.dropFirst(2)).padding(toLength: 76, withPad: " ", startingAt: 0) + surface + "  "
                } else {
                    ansi += text.padding(toLength: 80, withPad: " ", startingAt: 0)
                }
            }
            let cursor = TerminalMultilineCursorNavigation.Point(column: wrapped ? 10 : 4, row: wrapped ? 9 : 8)
            ansi += surface + "\u{1b}[\(cursor.row + 1);\(cursor.column + 1)H"
            terminal.feed(text: ansi)
            let lines = TerminalMultilineCursorNavigation.lines(in: terminal)
            #expect(!lines[4].isShaded && !lines[5].isShaded)
            #expect(lines[cursor.row].isShaded)
            for row in rows.indices {
                #expect(CodexQuestionInputArea.contains(lines: lines, cursor: cursor, tap: .init(column: 30, row: row)) == (7...10).contains(row))
            }

            // Broken surface margins must still stop the header scan.
            for column in [1, 78] {
                var broken = lines
                broken[5].cells[column].inputBackground = false
                #expect(!CodexQuestionInputArea.contains(lines: broken, cursor: cursor, tap: .init(column: 30, row: 10)))
            }
            // Allow selection styles only above the composer, never within it.
            for row in [8, 9, 10] {
                var broken = lines
                broken[row].cells[30].inputBackground = false
                #expect(!CodexQuestionInputArea.contains(lines: broken, cursor: cursor, tap: .init(column: 30, row: 10)))
            }
        }

        final private class Delegate: TerminalDelegate {
            func send(source _: Terminal, data _: ArraySlice<UInt8>) { }
        }
    }
#endif
