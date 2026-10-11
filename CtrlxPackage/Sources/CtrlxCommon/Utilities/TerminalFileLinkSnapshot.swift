#if canImport(SwiftTerm)
import SwiftTerm

/// One viewport result for decorations, hover and activation. Never retains scrollback history.
@MainActor
public struct TerminalFileLinkSnapshot {
    private struct LineStamp: Equatable {
        let line: BufferLine?
        let generation: UInt64?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.line === rhs.line && lhs.generation == rhs.generation
        }
    }

    private struct Key: Equatable {
        let buffer: ObjectIdentifier
        let columns: Int
        let rows: Int
        let scanRows: Range<Int>
        let trimmed: Int
        let cursorColumn: Int
        let cursorRow: Int
        let mouseModeActive: Bool
        let lines: [LineStamp]
    }

    private var key: Key?
    private var cachedLinks: [TerminalFileLink] = []

    public init() { }

    /// Call after feeding/extracting payloads, including changes outside the visible rows.
    public mutating func invalidate() { key = nil }

    /// Native scroll views can supply actual content rows when their offset leads yDisp.
    public mutating func links(
        terminal: Terminal,
        visibleRows: Range<Int>? = nil,
        cellPayload: (Int, Int) -> String?
    ) -> [TerminalFileLink] {
        let buffer = terminal.buffer
        let visibleRows = visibleRows ?? buffer.yDisp..<(buffer.yDisp + terminal.rows)
        guard !visibleRows.isEmpty else {
            key = nil
            cachedLinks = []
            return []
        }
        let start = max(0, visibleRows.lowerBound - 4)
        let end = min(start + 256, max(start, visibleRows.upperBound + 4))
        let current = Key(
            buffer: ObjectIdentifier(buffer), columns: terminal.cols, rows: terminal.rows,
            scanRows: start..<end, trimmed: buffer.totalLinesTrimmed,
            cursorColumn: buffer.x, cursorRow: buffer.y, mouseModeActive: terminal.mouseMode != .off,
            lines: (start...end).map { row in
                let line = terminal.getScrollInvariantLine(row: row + buffer.totalLinesTrimmed)
                return LineStamp(line: line, generation: line?.generation)
            }
        )
        if current != key {
            cachedLinks = TerminalFileLinkDetector.links(terminal: terminal, rows: start..<end, cellPayload: cellPayload)
            key = current
        }
        return cachedLinks
    }
}
#endif
