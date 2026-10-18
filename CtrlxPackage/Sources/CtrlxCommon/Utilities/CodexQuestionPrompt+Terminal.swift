#if canImport(SwiftTerm)
    import SwiftTerm

    public extension CodexQuestionPrompt {
        init(terminal: Terminal) throws(RecognitionError) {
            let row = terminal.buffer.y
            guard row >= 0, row < terminal.rows else { throw .cursorOutsideScreen }
            // Only the composer and its nearby footer. The caller must establish
            // that the viewport is at the live bottom before opening Questions.
            let firstRow = max(0, row - 8)
            let lines = (firstRow...row).map {
                terminal.getLine(row: $0)?.translateToString(
                    trimRight: true,
                    skipNullCellsFollowingWide: true,
                    characterProvider: { cell in
                        // Unwritten terminal cells render as spaces, but the default
                        // exporter returns NUL. Keep them as separators, not text.
                        // The terminal also resolves emoji/combined characters.
                        let character = terminal.getCharacter(for: cell)
                        return character == "\0" ? " " : character
                    }
                ) ?? ""
            }
            try self.init(validating: lines, cursorRow: row - firstRow, cursorColumn: terminal.buffer.x)
        }
    }
#endif
