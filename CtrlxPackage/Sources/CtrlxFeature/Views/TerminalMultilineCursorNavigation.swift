/// Cross-row taps need stronger evidence than the legacy same-row shortcut.
/// A terminal has no editor model: recognize a prompt inside a bounded input
/// surface, and leave unrecognized output, history and other TUIs alone.
enum TerminalMultilineCursorNavigation {
    struct Point: Equatable, Sendable {
        var column: Int
        var row: Int
    }

    struct Cell: Equatable, Sendable {
        var character: Character
        var width: Int
        /// A non-default background matching the live cursor's background.
        var inputBackground: Bool = false

        var isBlank: Bool { character == " " || character == "\0" || width == 0 }
    }

    struct Line: Equatable, Sendable {
        var cells: [Cell]

        var isBlank: Bool { cells.allSatisfy(\.isBlank) }
        var isShaded: Bool {
            // SwiftTerm may leave a wide glyph's continuation cell at default
            // attributes; its rendered background belongs to the leading cell.
            cells.count >= 4 && cells.dropFirst().dropLast().allSatisfy {
                $0.width == 0 || $0.inputBackground
            }
        }

        var isBorder: Bool {
            let visible = cells.filter { !$0.isBlank }
            return visible.count >= 8
                && visible.count >= cells.count - 2
                && visible.allSatisfy { "─━-╭╮╰╯┌┐└┘".contains($0.character) }
        }

        var inputColumn: Int? {
            guard let prompt = cells.firstIndex(where: { !$0.isBlank }), prompt <= 2,
                  "›❯>".contains(cells[prompt].character),
                  cells.indices.contains(prompt + 1), cells[prompt + 1].isBlank
            else { return nil }
            return prompt + 2
        }
    }

    struct Region: Equatable, Sendable {
        var firstRow: Int
        var inputColumn: Int
        var lines: [Line]

        var rows: Range<Int> { firstRow..<(firstRow + lines.count) }

        func target(_ point: Point) -> Point? {
            guard rows.contains(point.row) else { return nil }
            let cells = lines[point.row - firstRow].cells
            let lastCharacter = cells.lastIndex(where: { !$0.isBlank })
            let end = lastCharacter.map { $0 + max(1, cells[$0].width) } ?? inputColumn
            // Do not send Right past a short line's end: that enters the next
            // line. Blank padding below the draft is not part of the region.
            var column = min(max(inputColumn, point.column), min(end, cells.count - 1))
            while column > inputColumn, cells[column].width == 0 { column -= 1 }
            return Point(column: column, row: point.row)
        }
    }

    static func region(lines: [Line], cursor: Point) -> Region? {
        guard lines.indices.contains(cursor.row),
              lines[cursor.row].cells.indices.contains(cursor.column)
        else { return nil }

        var first = cursor.row
        var last = cursor.row
        if lines[cursor.row].isShaded {
            while first > 0, lines[first - 1].isShaded { first -= 1 }
            while last + 1 < lines.count, lines[last + 1].isShaded { last += 1 }
        } else {
            // Unshaded prompt boxes (e.g. Claude Code) must have BOTH borders.
            // A bare shell prompt does not establish a multiline editor range.
            guard let top = lines[..<cursor.row].lastIndex(where: \.isBorder),
                  let bottom = lines[(cursor.row + 1)...].firstIndex(where: \.isBorder)
            else { return nil }
            first = top + 1
            last = bottom - 1
        }

        while first < cursor.row, lines[first].isBlank { first += 1 }
        while last > cursor.row, lines[last].isBlank { last -= 1 }
        guard let inputColumn = lines[first].inputColumn,
              cursor.column >= inputColumn,
              !lines[cursor.row].isBorder
        else { return nil }
        let width = lines[first].cells.count
        for row in first...last {
            guard lines[row].cells.count == width else { return nil }
            if row != first {
                guard lines[row].cells.prefix(inputColumn).allSatisfy(\.isBlank),
                      !lines[row].isBorder
                else { return nil }
            }
        }
        return Region(firstRow: first, inputColumn: inputColumn, lines: Array(lines[first...last]))
    }

    /// Two phases, no polling/retries or predicted preferred column. Up/Down
    /// belongs to the remote editor; only its returned cursor tells us where
    /// it landed on a short, soft-wrapped or wide-character line.
    struct PendingMove: Sendable {
        let region: Region
        let origin: Point
        let target: Point
        let displayRow: Int
        let deadline: ContinuousClock.Instant

        init?(lines: [Line], cursor: Point, tap: Point, displayRow: Int,
              now: ContinuousClock.Instant = .now) {
            guard tap.row != cursor.row,
                  let region = TerminalMultilineCursorNavigation.region(lines: lines, cursor: cursor),
                  let target = region.target(tap)
            else { return nil }
            self.region = region
            self.origin = cursor
            self.target = target
            self.displayRow = displayRow
            self.deadline = now.advanced(by: .seconds(2))
        }

        var verticalSteps: Int { target.row - origin.row }

        enum Progress: Equatable {
            case waiting
            case cancelled
            case horizontalSteps(Int)
        }

        func progress(lines: [Line], cursor: Point, displayRow: Int,
                      now: ContinuousClock.Instant = .now) -> Progress {
            guard now < deadline, displayRow == self.displayRow,
                  lines.count >= region.rows.upperBound,
                  Array(lines[region.rows]) == region.lines,
                  cursor.column >= region.inputColumn,
                  (min(origin.row, target.row)...max(origin.row, target.row)).contains(cursor.row)
            else { return .cancelled }
            guard cursor.row == target.row else { return .waiting }
            let cells = region.lines[target.row - region.firstRow].cells
            guard cursor.column < cells.count else { return .cancelled }
            return .horizontalSteps(TerminalCursorTapNavigation.signedStepCount(
                cursorColumn: cursor.column,
                tappedColumn: target.column,
                cellWidths: cells.map(\.width)
            ))
        }
    }
}

#if canImport(SwiftTerm)
    import SwiftTerm

    extension TerminalMultilineCursorNavigation {
        /// Read terminal cells (including wide-character continuation cells),
        /// never the native keyboard's incomplete shadow draft.
        static func lines(in terminal: Terminal, backgroundAt point: Point? = nil) -> [Line] {
            let buffer = terminal.buffer
            let reference = point ?? Point(column: buffer.x, row: buffer.y)
            guard let cursorLine = terminal.getScrollInvariantLine(row: buffer.yDisp + reference.row),
                  reference.column >= 0, reference.column < min(cursorLine.count, terminal.cols)
            else { return [] }
            var backgroundColumn = reference.column
            while backgroundColumn > 0, cursorLine.getWidth(index: backgroundColumn) == 0 {
                backgroundColumn -= 1
            }
            let background = cursorLine[backgroundColumn].attribute.bg
            let isDistinct = background != .defaultColor && background != .defaultInvertedColor
            return (0..<terminal.rows).map { row in
                guard let line = terminal.getScrollInvariantLine(row: buffer.yDisp + row) else {
                    return .init(cells: [])
                }
                return .init(cells: (0..<min(line.count, terminal.cols)).map { column in
                    let cell = line[column]
                    return .init(
                        character: terminal.getCharacter(for: cell),
                        width: Int(cell.width),
                        inputBackground: isDistinct && cell.attribute.bg == background
                            && !cell.attribute.style.contains(.inverse)
                    )
                })
            }
        }
    }
#endif
