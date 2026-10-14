import Foundation

/// A completed single tap has exactly one owner. Multi-tap/selection gesture
/// arbitration happens before this policy; links remain local in either mode.
enum TerminalContentTapRouting {
    enum Action: Equatable {
        case ignore
        case openLink
        case mouseClick
        case cursorNavigation
        case toggleKeyboard
    }

    static func action(
        selectionActive: Bool,
        hasLink: Bool,
        canSendInput: Bool,
        mouseModeActive: Bool,
        isLiveScreen: Bool,
        isEmptyInputArea: Bool = false
    ) -> Action {
        guard !selectionActive else { return .ignore }
        if hasLink {
            return .openLink
        }
        guard canSendInput, isLiveScreen else { return .ignore }
        if isEmptyInputArea {
            return .toggleKeyboard
        }
        return mouseModeActive ? .mouseClick : .cursorNavigation
    }

    static func isInputArea(
        lines: [TerminalMultilineCursorNavigation.Line],
        cursor: TerminalMultilineCursorNavigation.Point,
        tap: TerminalMultilineCursorNavigation.Point,
        mouseModeActive: Bool
    ) -> Bool {
        guard
            lines.indices.contains(cursor.row), lines.indices.contains(tap.row),
            lines[cursor.row].cells.indices.contains(cursor.column),
            lines[tap.row].cells.indices.contains(tap.column) else { return false }
        if let region = TerminalMultilineCursorNavigation.region(lines: lines, cursor: cursor) {
            return region.rows.contains(tap.row)
        }
        // Mouse-reporting TUIs also contain clickable output and menus.
        // Without a bounded editor, require a recognizable prompt on this row.
        if mouseModeActive {
            guard let inputColumn = lines[cursor.row].inputColumn, cursor.column >= inputColumn else { return false }
        }
        return tap.row == cursor.row
    }

    static func isEmptyInputArea(
        lines: [TerminalMultilineCursorNavigation.Line],
        cursor: TerminalMultilineCursorNavigation.Point,
        tap: TerminalMultilineCursorNavigation.Point,
        mouseModeActive: Bool
    ) -> Bool {
        guard
            lines.indices.contains(cursor.row), lines.indices.contains(tap.row),
            lines[tap.row].cells.indices.contains(tap.column) else { return false }
        let line = lines[cursor.row]
        guard line.cells.indices.contains(cursor.column) else { return false }
        guard
            cursor.column >= 2, line.cells[cursor.column - 1].isBlank,
            "›❯>$%#".contains(line.cells[cursor.column - 2].character) else { return false }
        if let inputColumn = line.inputColumn, cursor.column != inputColumn {
            return false
        }
        // A boxed editor may contain a draft below a cursor moved to Home.
        // Never mistake its first empty line for an empty whole input.
        let region = TerminalMultilineCursorNavigation.region(lines: lines, cursor: cursor)
        if let region {
            guard
                region.firstRow == cursor.row, cursor.column == region.inputColumn,
                region.lines.dropFirst().allSatisfy(\.isBlank) else { return false }
        } else if mouseModeActive, line.inputColumn == nil {
            return false
        }
        let text = String(line.cells.dropFirst(cursor.column).filter { $0.width > 0 }.map(\.character))
            .replacingOccurrences(of: "\0", with: " ").trimmingCharacters(in: .whitespaces)
        // Codex paints this placeholder into the terminal buffer. Other text
        // remains a draft, regardless of its color or our keyboard shadow.
        let placeholder = line.cells[cursor.column - 2].character == "›"
            && text == "Ask Codex to do anything"
        guard text.isEmpty || placeholder else { return false }
        if tap.row == cursor.row {
            return true
        }
        guard region != nil, lines[tap.row].isBlank else { return false }
        return (min(tap.row, cursor.row)...max(tap.row, cursor.row)).allSatisfy {
            lines[$0].isShaded && ($0 == cursor.row || lines[$0].isBlank)
        }
    }
}

#if canImport(SwiftTerm)
    import SwiftTerm

    extension TerminalContentTapRouting {
        /// Encode with SwiftTerm's negotiated protocol (SGR, X10, UTF8, etc.),
        /// never as text keys. The caller collects the synchronous delegate
        /// writes into one raw-input batch so press/release cannot interleave.
        @discardableResult
        static func reportMouseClick(
            terminal: Terminal,
            column: Int,
            absoluteRow: Int,
            liveDisplayRow: Int,
            pixelX: Int,
            pixelY: Int
        ) -> Bool {
            guard
                terminal.mouseMode != .off,
                terminal.buffer.yDisp == liveDisplayRow,
                column >= 0, column < terminal.cols,
                absoluteRow >= liveDisplayRow,
                absoluteRow - liveDisplayRow < terminal.rows,
                pixelX >= 0, pixelY >= 0 else { return false }

            let row = absoluteRow - liveDisplayRow
            func send(release: Bool) {
                let flags = terminal.encodeButton(
                    button: 0, release: release, shift: false, meta: false, control: false
                )
                terminal.sendEvent(buttonFlags: flags, x: column, y: row, pixelX: pixelX, pixelY: pixelY)
            }
            send(release: false)
            // X10 tracking requests only presses, unlike VT200/button/any-event.
            if terminal.mouseMode != .x10 {
                send(release: true)
            }
            return true
        }
    }
#endif
