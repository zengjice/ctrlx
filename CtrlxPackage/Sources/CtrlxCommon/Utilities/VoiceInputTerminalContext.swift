#if canImport(SwiftTerm)
    import SwiftTerm

    public extension VoiceInputContext {
        /// Read once when recording starts, never on terminal output. Locate the tail
        /// without copying or walking all retained scrollback; preserve soft wraps.
        @MainActor
        static func recentTerminalText(_ terminal: Terminal) -> String? {
            let trimmed = terminal.buffer.totalLinesTrimmed
            guard terminal.getScrollInvariantLine(row: trimmed) != nil else { return nil }
            var lower = 0
            var upper = max(1, terminal.rows)
            while terminal.getScrollInvariantLine(row: trimmed + upper) != nil {
                lower = upper
                upper *= 2
            }
            while upper - lower > 1 {
                let middle = lower + (upper - lower) / 2
                if terminal.getScrollInvariantLine(row: trimmed + middle) == nil {
                    upper = middle
                } else {
                    lower = middle
                }
            }
            let text = terminal.getText(
                start: Position(col: 0, row: max(0, upper - 512)),
                end: Position(col: terminal.cols, row: upper - 1)
            )
            return terminalExcerpt(text)
        }
    }
#endif
