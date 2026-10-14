import Foundation
import SwiftTerm

/// Only blank cells beside the current prompt (including its shaded padding).
/// Native placeholder text is left intact and remains selectable.
enum MacTerminalVoiceInputRegion {
    static func contains(column: Int, row: Int, in terminal: Terminal) -> Bool {
        let cursor = terminal.buffer
        guard
            terminal.isCursorVisible, !terminal.synchronizedOutputActive,
            (0..<terminal.cols).contains(column), (0..<terminal.rows).contains(row),
            cursor.x >= 2, cursor.x < terminal.cols,
            let input = terminal.getLine(row: cursor.y),
            let clicked = terminal.getLine(row: row),
            isBlank(clicked[column], in: terminal) else { return false }

        // Require a prompt directly before the insertion point. Text to the
        // right may be the application's own placeholder; don't infer from grey.
        let prefix = input.translateToString(trimRight: false, startCol: 0, endCol: cursor.x)
        guard ["› ", "❯ ", "> ", "$ ", "% ", "# "].contains(where: prefix.hasSuffix) else { return false }
        if row == cursor.y {
            return column >= cursor.x
        }

        let background = input[cursor.x].attribute.bg
        guard background != .defaultColor, background != .defaultInvertedColor else { return false }
        // Codex's input has blank padding above/below it. Stop at any boundary
        // or text row, so an output region never joins the input's hit area.
        for candidate in min(row, cursor.y)...max(row, cursor.y) {
            guard
                let line = terminal.getLine(row: candidate),
                line[column].attribute.bg == background,
                line[cursor.x].attribute.bg == background else { return false }
            if
                candidate != cursor.y,
                !(0..<terminal.cols).allSatisfy({ isBlank(line[$0], in: terminal) }) {
                return false
            }
        }
        return true
    }

    private static func isBlank(_ cell: CharData, in terminal: Terminal) -> Bool {
        let character = terminal.getCharacter(for: cell)
        return cell.width == 1 && (character == " " || character == "\0")
    }
}
