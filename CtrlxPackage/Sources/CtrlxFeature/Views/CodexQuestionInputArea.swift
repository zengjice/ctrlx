import Foundation

/// Bound the focused composer by its prompt and footer. Selected options can
/// change color or use inverse video inside the popup's two-column margins.
enum CodexQuestionInputArea {
    typealias Navigation = TerminalMultilineCursorNavigation

    static func contains(lines: [Navigation.Line], cursor: Navigation.Point, tap: Navigation.Point) -> Bool {
        guard
            lines.indices.contains(cursor.row), lines.indices.contains(tap.row),
            lines[cursor.row].cells.indices.contains(cursor.column),
            lines[cursor.row].isShaded else { return false }

        var top = cursor.row
        var bottom = cursor.row
        while top > 0, hasSurfaceMargins(lines[top - 1]) {
            top -= 1
        }
        while bottom + 1 < lines.count, lines[bottom + 1].isShaded {
            bottom += 1
        }
        while top < cursor.row, lines[top].isBlank {
            top += 1
        }
        guard
            lines[top].isShaded, isQuestionHeader(text(lines[top])), top < cursor.row, cursor.row < bottom,
            let prompt = (top + 1...cursor.row).last(where: {
                lines[$0].inputColumn == 4 && lines[$0].cells[2].character == "›"
            }),
            let footer = (cursor.row + 1...bottom).first(where: {
                !lines[$0].isBlank && !lines[$0].cells.prefix(4).allSatisfy(\.isBlank)
            }) else { return false }

        let hints = (footer...bottom).map { text(lines[$0]) }.joined(separator: " ")
        let firstHint = text(lines[footer])
        guard
            firstHint.contains("to submit") || firstHint.contains("to clear notes") || firstHint.hasPrefix("option "),
            !hints.contains("to add notes"),
            hints.contains("to submit answer") || hints.contains("to submit all"),
            hints.contains("to interrupt") || hints.contains("to clear notes")
        else { return false }

        let width = lines[prompt].cells.count
        guard
            lines[prompt].isShaded,
            cursor.column >= 4, cursor.column < width - 2,
            (prompt + 1..<footer).allSatisfy({
                lines[$0].cells.count == width && lines[$0].isShaded && lines[$0].cells.prefix(4).allSatisfy(\.isBlank)
            }) else { return false }

        // Only the composer's single top padding row belongs to the input;
        // do not include the question or the gap above the choices.
        let first = prompt > top + 1 && lines[prompt - 1].isBlank && lines[prompt - 1].isShaded ? prompt - 1 : prompt
        return (first..<footer).contains(tap.row) && (2..<width - 2).contains(tap.column)
    }

    private static func hasSurfaceMargins(_ line: Navigation.Line) -> Bool {
        guard line.cells.count >= 4 else { return false }
        return [1, line.cells.count - 2].allSatisfy {
            line.cells[$0].isBlank && line.cells[$0].inputBackground
        }
    }

    private static func text(_ line: Navigation.Line) -> String {
        String(line.cells.filter { $0.width > 0 }.map { $0.isBlank ? " " : $0.character })
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isQuestionHeader(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count >= 2, words[0] == "Question" else { return false }
        let progress = words[1].split(separator: "/")
        guard progress.count == 2, let current = Int(progress[0]), let count = Int(progress[1]) else { return false }
        return current > 0 && current <= count
    }
}
