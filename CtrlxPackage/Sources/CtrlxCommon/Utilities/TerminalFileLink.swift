import CtrlxNetworking
import Foundation

public struct TerminalFileLink: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public let row: Int
        public let columns: Range<Int>
    }
    public let path: String
    public let spans: [Span]

    public func contains(column: Int, row: Int) -> Bool {
        spans.contains { $0.row == row && $0.columns.contains(column) }
    }
}

/// Pure, bounded recognition. Filesystem validation happens only after activation.
public enum TerminalFileLinkDetector {
    public struct Cell: Sendable {
        public let character: Character
        public let column: Int
        public let width: Int
        public init(_ character: Character, column: Int, width: Int = 1) {
            self.character = character
            self.column = column
            self.width = width
        }
    }
    public struct Row: Sendable {
        public let number: Int
        public let cells: [Cell]
        public let wrapped: Bool
        public init(number: Int, cells: [Cell], wrapped: Bool = false) {
            self.number = number
            self.cells = cells
            self.wrapped = wrapped
        }
    }
    private struct Unit {
        let character: Character
        let row: Int
        let columns: Range<Int>
    }

    public static func links(rows: [Row], columns: Int) -> [TerminalFileLink] {
        guard columns > 0, columns <= 1024 else { return [] }
        var units: [Unit] = []
        for row in rows.prefix(256) {
            if !units.isEmpty, !row.wrapped {
                units.append(.init(character: "\n", row: row.number, columns: 0..<0))
            }
            let cells = row.cells.drop(while: { $0.character.isWhitespace })
            let end = cells.lastIndex(where: { !$0.character.isWhitespace })
            guard let end else { continue }
            for cell in cells[...end] where cell.width > 0 {
                units.append(.init(character: cell.character, row: row.number,
                                   columns: cell.column..<(cell.column + cell.width)))
            }
        }
        let webPrefixes = [Array("https://"), Array("http://"), Array("ftp://")]
        var result: [TerminalFileLink] = []
        var index = 0
        while index < units.count {
            // A web URL owns its entire token, including parentheses and embedded URIs.
            if (units[index].character == "h" || units[index].character == "f"), webPrefixes.contains(where: { scheme in
                units[index...].starts(with: scheme, by: { $0.character == $1 })
            }) {
                while index < units.count, !units[index].character.isWhitespace { index += 1 }
                continue
            }
            guard units[index].character == "<" else {
                index += 1
                continue
            }
            var content: [Unit] = []
            var marker = ""
            var cursor = index
            var matched = false
            while cursor < units.count, content.count < RepositoryFileLink.maximumLength {
                let unit = units[cursor]
                if unit.character == "\n" {
                    // Only layout breaks may disappear; literal filename spaces must be encoded.
                    if cursor > index, units[cursor - 1].character == "\n" { break }
                    cursor += 1
                    continue
                }
                guard !unit.character.isWhitespace else { break }
                marker.append(unit.character)
                content.append(unit)
                cursor += 1
                if content.count <= RepositoryFileLink.prefix.count,
                   !RepositoryFileLink.prefix.hasPrefix(marker) { break }
                if unit.character == ">" {
                    if let path = RepositoryFileLink.path(marker) {
                        var spans: [TerminalFileLink.Span] = []
                        for item in content {
                            if let last = spans.last, last.row == item.row, last.columns.upperBound == item.columns.lowerBound {
                                spans[spans.count - 1] = .init(row: last.row, columns: last.columns.lowerBound..<item.columns.upperBound)
                            } else {
                                spans.append(.init(row: item.row, columns: item.columns))
                            }
                        }
                        result.append(.init(path: path, spans: spans))
                        matched = true
                    }
                    break
                }
            }
            index = matched ? cursor : index + 1
        }
        return result
    }
}

#if canImport(SwiftTerm)
import SwiftTerm

extension TerminalFileLinkDetector {
    /// Rows/spans use buffer-relative UI coordinates; payload lookups use SwiftTerm's invariant rows.
    @MainActor
    public static func links(terminal: Terminal, rows: Range<Int>, cellPayload: (Int, Int) -> String?) -> [TerminalFileLink] {
        let trimmed = terminal.buffer.totalLinesTrimmed
        func bufferLine(at row: Int) -> BufferLine? { terminal.getScrollInvariantLine(row: row + trimmed) }
        func payloadAt(_ column: Int, row: Int) -> String? {
            (bufferLine(at: row)?[column].getPayload() as? String) ?? cellPayload(column, row + trimmed)
        }
        // SwiftTerm does not expose the live buffer origin. Locate its end only
        // if it is near these rows; history-only scans cannot contain live input.
        var lower = max(0, rows.lowerBound)
        var upper = max(lower, rows.upperBound) + terminal.rows
        let liveEndNearby = bufferLine(at: upper) == nil
        while liveEndNearby, lower < upper {
            let middle = lower + (upper - lower) / 2
            if bufferLine(at: middle) == nil { upper = middle }
            else { lower = middle + 1 }
        }
        let cursorRow = liveEndNearby ? max(0, lower - terminal.rows) + terminal.buffer.y : -1
        var inputStart = cursorRow
        var inputEnd = cursorRow
        while inputStart > 0, cursorRow - inputStart < 16,
              bufferLine(at: inputStart)?.isWrapped == true { inputStart -= 1 }
        while liveEndNearby, inputEnd - cursorRow < 16,
              bufferLine(at: inputEnd + 1)?.isWrapped == true { inputEnd += 1 }
        // Codex redraws its multiline composer with hard line breaks on a
        // distinct background. Keep those rows available for cursor editing.
        if liveEndNearby, terminal.mouseMode != .off, let cursorLine = bufferLine(at: cursorRow) {
            let background = cursorLine[min(max(0, terminal.buffer.x), terminal.cols - 1)].attribute.bg
            if background != .defaultColor, background != .defaultInvertedColor {
                func isComposerRow(_ row: Int) -> Bool {
                    guard let line = bufferLine(at: row) else { return false }
                    return (min(2, terminal.cols)..<terminal.cols).allSatisfy {
                        line[$0].attribute.bg == background && !line[$0].attribute.style.contains(.inverse)
                    }
                }
                while inputStart > 0, cursorRow - inputStart < 16, isComposerRow(inputStart - 1) { inputStart -= 1 }
                while inputEnd - cursorRow < 16, isComposerRow(inputEnd + 1) { inputEnd += 1 }
            }
        }
        let excluded = liveEndNearby ? inputStart...inputEnd : -1 ... -1
        var inputRows: [Row] = []
        for row in rows.prefix(256) {
            guard let line = bufferLine(at: row) else { continue }
            var cells: [Cell] = []
            var col = 0
            while col < terminal.cols {
                let data = line[col]
                if let payload = payloadAt(col, row: row), payload.contains(";") {
                    let start = col
                    while col < terminal.cols, payloadAt(col, row: row) == payload { col += 1 }
                    cells.append(.init(" ", column: start, width: col - start))
                    continue
                }
                if data.width > 0 {
                    let character = terminal.getCharacter(for: data)
                    cells.append(.init(character == "\0" ? " " : character, column: col, width: Int(data.width)))
                } else if data.getCharacter() == "\0", col == 0 || line[col - 1].width < 2 {
                    cells.append(.init(" ", column: col))
                }
                col += 1
            }
            // Preserve full-width soft wraps; hard breaks trim unused terminal cells.
            if bufferLine(at: row + 1)?.isWrapped != true {
                while cells.last?.character.isWhitespace == true { cells.removeLast() }
            } else {
                // A wide character can wrap with one unused cell left on the preceding row.
                while let last = cells.last, last.character.isWhitespace, line[last.column].getCharacter() == "\0" { cells.removeLast() }
            }
            inputRows.append(.init(number: row, cells: cells, wrapped: line.isWrapped))
        }
        if let last = inputRows.last, bufferLine(at: last.number + 1)?.isWrapped == true {
            while inputRows.last?.wrapped == true { inputRows.removeLast() }
            if !inputRows.isEmpty { inputRows.removeLast() }
        }
        return links(rows: inputRows, columns: terminal.cols).filter { link in
            !link.spans.contains { excluded.contains($0.row) }
        }
    }
}
#endif
