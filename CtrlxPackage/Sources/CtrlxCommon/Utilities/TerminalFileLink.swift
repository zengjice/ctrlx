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
        var continuation = false
        var filenameContinuation = false
        var isWebURL = false

        var continuesEnclosure: Bool { continuation || filenameContinuation }
    }

    public static func links(rows: [Row], columns: Int) -> [TerminalFileLink] {
        guard columns > 0, columns <= 1024 else { return [] }
        var units: [Unit] = []
        var previous: Row?
        for row in rows.prefix(256).drop(while: \.wrapped) {
            if let previous, !row.wrapped {
                let end = previous.cells.last(where: { !$0.character.isWhitespace })
                units.append(.init(character: "\n", row: row.number, columns: 0..<0,
                                   continuation: end.map { $0.column + $0.width >= columns - 4 } ?? false,
                                   filenameContinuation: end.map {
                                       filenameTailOverflows(row, remainingColumns: columns - $0.column - $0.width)
                                   } ?? false))
            }
            for cell in row.cells where cell.width > 0 {
                units.append(.init(character: cell.character, row: row.number,
                                   columns: cell.column..<(cell.column + cell.width)))
            }
            previous = row
        }
        excludeWebURLs(in: &units)
        // Prose punctuation separates bare paths; enclosed paths and OSC 8
        // targets retain their literal filename characters.
        let delimiters = Set("<>\"'`()[]{}|，。；：！？、" as String)
        let pairs: [Character: Character] = ["(": ")", "[": "]", "\"": "\"", "'": "'", "`": "`"]
        func isDelimiter(at index: Int) -> Bool {
            let character = units[index].character
            // Keep word apostrophes in their token, not as the start of a quoted path.
            if character == "'", index > 0, index + 1 < units.count,
               units[index - 1].character.isLetter || units[index - 1].character.isNumber,
               units[index + 1].character.isLetter || units[index + 1].character.isNumber { return false }
            return delimiters.contains(character)
        }
        var result: [TerminalFileLink] = []
        var index = 0
        while index < units.count {
            if units[index].isWebURL {
                index += 1
                continue
            }
            if let close = pairs[units[index].character], isDelimiter(at: index) {
                guard let end = closingIndex(in: units, from: index, close: close) else {
                    // Drop the incomplete wrapped fragment, not independent lines after it.
                    index = units[(index + 1)...].firstIndex(where: { $0.character == "\n" && !$0.continuesEnclosure }) ?? units.count
                    continue
                }
                let content = joinedEnclosedContent(Array(units[(index + 1)..<end]))
                if isTruncated(String(content.map(\.character))) {
                    index = end + 1
                    continue
                }
                if let link = makeLink(content) {
                    result.append(link)
                    index = end + 1
                    continue
                }
            }
            if units[index].character.isWhitespace || isDelimiter(at: index) {
                index += 1
                continue
            }
            let start = index
            while index < units.count, !units[index].character.isWhitespace, !isDelimiter(at: index) {
                index += 1
            }
            var token = Array(units[start..<index])
            if let end = incompleteFileURLEnd(in: units, token: token, end: index) {
                index = end
                continue
            }
            // Check before stripping punctuation: an ASCII ellipsis is not a period.
            guard !isTruncated(String(token.map(\.character))) else { continue }
            while let last = token.last, ".,;:!?。，；：！？".contains(last.character) { token.removeLast() }
            if let link = makeLink(token) { result.append(link) }
        }
        return result
    }

    /// Bare hard breaks carry no link target. Suppress a likely split URI and
    /// its continuation lines instead of making each fragment independently clickable.
    private static func incompleteFileURLEnd(in units: [Unit], token: [Unit], end: Int) -> Int? {
        guard token.starts(with: Array("file://"), by: { $0.character == $1 }) else { return nil }
        var end = end
        var last = token.last?.character
        var foundContinuation = false
        while end < units.count {
            var newline = end
            while newline < units.count, units[newline].character.isWhitespace, units[newline].character != "\n" { newline += 1 }
            guard newline < units.count, units[newline].character == "\n",
                  last == "/" || last == "-" || units[newline].continuation else { break }
            let lineEnd = units[(newline + 1)...].firstIndex(where: { $0.character == "\n" }) ?? units.count
            let text = String(units[(newline + 1)..<lineEnd].map(\.character)).trimmingCharacters(in: .whitespaces)
            // A new explicitly rooted path or prose line is independent, not a tail.
            guard let first = text.first, first.isLetter || first.isNumber || first == "_",
                  !text.contains(where: { $0.isWhitespace || ":<>\"'`()[]{}|，。；：！？、".contains($0) }),
                  text.contains("/") || text.contains(".") || text.hasSuffix("-") else { break }
            foundContinuation = true
            last = text.last
            end = lineEnd
        }
        return foundContinuation ? end : nil
    }

    /// Word wrapping can move a filename's final chunk and its closer together,
    /// leaving more than four cells unused. Do not extend this inference to bare URIs
    /// or to a new path/list/prose line that merely happens to overflow that space.
    private static func filenameTailOverflows(_ row: Row, remainingColumns: Int) -> Bool {
        let token = row.cells.drop(while: { $0.character.isWhitespace })
            .prefix(while: { !$0.character.isWhitespace })
        guard let closer = token.last, ")]\"'`".contains(closer.character),
              token.count > 1,
              token.dropLast().allSatisfy({
                  $0.character.isLetter || $0.character.isNumber || "._-…".contains($0.character)
              }) else { return false }
        return token.reduce(0) { $0 + $1.width } > remainingColumns
    }

    private static func closingIndex(in units: [Unit], from start: Int, close: Character) -> Int? {
        let open = units[start].character
        var depth = 1
        for index in (start + 1)..<min(units.count, start + 4097) {
            let unit = units[index]
            if unit.character == "\n", !unit.continuesEnclosure { return nil }
            if unit.character == close {
                depth -= 1
                if depth == 0 { return index }
            } else if open != close, unit.character == open {
                depth += 1
            }
        }
        return nil
    }

    private static func excludeWebURLs(in units: inout [Unit]) {
        let schemes = [Array("http://"), Array("https://"), Array("ftp://")]
        let delimiters = Set("<>\"'`|" as String)
        var index = 0
        while index < units.count {
            guard (units[index].character == "h" || units[index].character == "f"),
                  schemes.contains(where: { scheme in
                      units[index...].starts(with: scheme, by: { $0.character == $1 })
                  }) else {
                index += 1
                continue
            }
            // Parentheses can belong to a URL. Reserve the whole token before
            // splitting file candidates, including any path after a closing bracket.
            while index < units.count, !units[index].character.isWhitespace,
                  !delimiters.contains(units[index].character),
                  !units[index].character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                units[index].isWebURL = true
                index += 1
            }
        }
    }

    /// closingIndex has already checked the enclosure's hard-wrap boundaries.
    /// Truncation checks and link creation must use the same joined characters.
    private static func joinedEnclosedContent(_ units: [Unit]) -> [Unit] {
        var content: [Unit] = []
        var skipsIndent = false
        for unit in units {
            if unit.character == "\n" {
                while content.last?.character.isWhitespace == true { content.removeLast() }
                skipsIndent = true
            } else if skipsIndent && unit.character.isWhitespace {
                continue
            } else {
                skipsIndent = false
                content.append(unit)
            }
        }
        while content.first?.character.isWhitespace == true { content.removeFirst() }
        while content.last?.character.isWhitespace == true { content.removeLast() }
        return content
    }

    private static func makeLink(_ content: [Unit]) -> TerminalFileLink? {
        guard content.count <= 4096, !content.contains(where: \.isWebURL) else { return nil }
        let text = String(content.map(\.character))
        guard !isTruncated(text), let path = path(text), isConfidentTextPath(text) else { return nil }
        var spans: [TerminalFileLink.Span] = []
        for unit in content {
            if let last = spans.last, last.row == unit.row {
                spans[spans.count - 1] = .init(row: last.row, columns: last.columns.lowerBound..<unit.columns.upperBound)
            } else { spans.append(.init(row: unit.row, columns: unit.columns)) }
        }
        return .init(path: path, spans: spans)
    }

    private static func isTruncated(_ text: String) -> Bool {
        text.contains("…") || text.contains("...")
    }

    /// Text needs path-specific evidence; explicit OSC 8 targets bypass this heuristic.
    private static func isConfidentTextPath(_ text: String) -> Bool {
        if text.hasPrefix("file://") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return true }
        if text.hasPrefix("/") {
            // /review and similar single-component slash commands are ambiguous.
            return text.dropFirst().contains("/") || !(text as NSString).pathExtension.isEmpty
        }
        if text.hasPrefix(".") { return true } // Explicit hidden directory, e.g. .build-local/.
        let name = (text as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let suffix = name[name.index(after: dot)...]
        return !text.hasSuffix("/") && !suffix.isEmpty && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    public static func path(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if text.hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            let path = url.path(percentEncoded: false)
            return path.hasPrefix("/") && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? path : nil
        }
        guard !text.contains("://"), !text.hasPrefix("//"), !text.contains("\\"),
              text.contains("/"), text.count > 1,
              !text.contains(where: { "<>\"'`|".contains($0) }) else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") { return text }
        guard let first = text.first, first.isLetter || first.isNumber || first == "_" || first == ".",
              let head = text.split(separator: "/").first, !head.contains(":") else { return nil }
        return text
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
        var explicit: [TerminalFileLink] = []
        for row in rows.prefix(256) {
            guard let line = bufferLine(at: row) else { continue }
            var cells: [Cell] = []
            var col = 0
            while col < terminal.cols {
                let data = line[col]
                if let payload = payloadAt(col, row: row), let separator = payload.firstIndex(of: ";") {
                    let start = col
                    while col < terminal.cols, payloadAt(col, row: row) == payload { col += 1 }
                    var end = col
                    while end > start {
                        if line[end - 1].width == 0, end > start + 1, line[end - 2].width == 2 { break }
                        guard line[end - 1].getCharacter() == "\0" || line[end - 1].getCharacter().isWhitespace else { break }
                        end -= 1
                    }
                    let uri = String(payload[payload.index(after: separator)...])
                    if end > start, !excluded.contains(row), uri.hasPrefix("file://"), let path = path(uri) {
                        explicit.append(.init(path: path, spans: [.init(row: row, columns: start..<end)]))
                    }
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
        return explicit + links(rows: inputRows, columns: terminal.cols).filter { link in
            !link.spans.contains { excluded.contains($0.row) }
        }
    }
}
#endif
