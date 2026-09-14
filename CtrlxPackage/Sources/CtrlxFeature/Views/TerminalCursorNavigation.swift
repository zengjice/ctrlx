/// Serializes tap-to-position keys against real terminal feedback. Only the
/// latest valid destination is retained; taps never accumulate a key backlog.
struct TerminalCursorNavigation {
    typealias Navigation = TerminalMultilineCursorNavigation
    typealias Point = Navigation.Point
    typealias Line = Navigation.Line

    enum Steps: Equatable {
        case vertical(Int)
        case horizontal(Int)
    }

    private struct Context {
        let region: Navigation.Region
        let legacyLine: Bool
        let displayRow: Int
        let rowCount: Int

        func target(_ tap: Point) -> Point? {
            if !legacyLine { return region.target(tap) }
            guard tap.row == region.firstRow, let line = region.lines.first,
                  !line.cells.isEmpty else { return nil }
            var column = min(max(0, tap.column), line.cells.count - 1)
            while column > 0, line.cells[column].width == 0 { column -= 1 }
            return Point(column: column, row: tap.row)
        }

        func matches(_ lines: [Line], displayRow: Int) -> Bool {
            self.displayRow == displayRow && lines.count == rowCount
                && lines.count >= region.rows.upperBound
                && Array(lines[region.rows]) == region.lines
        }

        func contains(_ cursor: Point) -> Bool {
            region.rows.contains(cursor.row) && cursor.column >= region.inputColumn
                && cursor.column < region.lines[cursor.row - region.firstRow].cells.count
        }
    }

    private enum Flight {
        case vertical(Navigation.PendingMove)
        case horizontal(origin: Point, target: Point)
    }

    private struct Pending {
        let context: Context
        var target: Point
        var flight: Flight?
        var deadline: ContinuousClock.Instant
    }

    private var pending: Pending?
    var isPending: Bool { pending != nil }
    var displayRow: Int? { pending?.context.displayRow }

    mutating func cancel() { pending = nil }

    mutating func request(lines: [Line], cursor: Point, tap: Point, displayRow: Int,
                          isStable: Bool, now: ContinuousClock.Instant = .now) -> Steps? {
        if let pending, now >= pending.deadline { cancel() }
        if let current = pending {
            // A redraw can temporarily change cells/cursor. Validate it only
            // when complete, but never accept a tap outside the captured input.
            guard current.context.displayRow == displayRow,
                  let target = current.context.target(tap) else { return nil }
            pending?.target = target
        } else {
            let region: Navigation.Region
            let legacyLine: Bool
            if isStable, let input = Navigation.region(lines: lines, cursor: cursor) {
                region = input
                legacyLine = false
            } else if !isStable {
                // The hidden cursor may be visiting output while redrawing.
                // Use the tapped, bounded prompt as evidence, then require the
                // real cursor to return to that same unchanged input surface.
                // Blank rows are ambiguous with padding until the cursor returns.
                guard lines.indices.contains(tap.row), !lines[tap.row].isBlank,
                      let input = Navigation.region(lines: lines, cursor: Point(
                          column: max(0, lines[tap.row].cells.count - 1), row: tap.row
                      )) else { return nil }
                region = input
                legacyLine = false
            } else {
                // Preserve same-row placement for unrecognized shell prompts.
                guard tap.row == cursor.row, lines.indices.contains(cursor.row) else { return nil }
                region = .init(firstRow: cursor.row, inputColumn: 0, lines: [lines[cursor.row]])
                legacyLine = true
            }
            let context = Context(region: region, legacyLine: legacyLine,
                                  displayRow: displayRow, rowCount: lines.count)
            guard let target = context.target(tap) else { return nil }
            pending = Pending(context: context, target: target, deadline: now.advanced(by: .seconds(2)))
        }
        return advance(lines: lines, cursor: cursor, displayRow: displayRow, isStable: isStable, now: now)
    }

    mutating func advance(lines: [Line], cursor: Point, displayRow: Int,
                          isStable: Bool, now: ContinuousClock.Instant = .now) -> Steps? {
        guard var current = pending else { return nil }
        guard now < current.deadline, displayRow == current.context.displayRow else {
            cancel()
            return nil
        }
        guard isStable else { return nil }
        guard current.context.matches(lines, displayRow: displayRow), current.context.contains(cursor) else {
            cancel()
            return nil
        }

        switch current.flight {
        case let .vertical(move):
            switch move.progress(lines: lines, cursor: cursor, displayRow: displayRow, now: now) {
            case .waiting: return nil
            case .cancelled:
                cancel()
                return nil
            case .horizontalSteps:
                // Arrived vertically. Re-plan towards the latest tap instead of
                // correcting an obsolete target's column first.
                current.flight = nil
            }
        case let .horizontal(origin, target):
            guard cursor.row == target.row,
                  (min(origin.column, target.column)...max(origin.column, target.column)).contains(cursor.column)
            else {
                cancel()
                return nil
            }
            guard cursor == target else { return nil }
            current.flight = nil
        case nil:
            break
        }

        guard cursor != current.target else {
            cancel()
            return nil
        }
        let steps: Steps
        if cursor.row != current.target.row {
            guard let move = Navigation.PendingMove(lines: lines, cursor: cursor,
                                                    tap: current.target, displayRow: displayRow, now: now) else {
                cancel()
                return nil
            }
            current.flight = .vertical(move)
            steps = .vertical(move.verticalSteps)
        } else {
            let count = TerminalCursorTapNavigation.signedStepCount(
                cursorColumn: cursor.column, tappedColumn: current.target.column,
                cellWidths: lines[cursor.row].cells.map(\.width)
            )
            guard count != 0 else {
                cancel()
                return nil
            }
            current.flight = .horizontal(origin: cursor, target: current.target)
            steps = .horizontal(count)
        }
        current.deadline = now.advanced(by: .seconds(2))
        pending = current
        return steps
    }
}
