#if canImport(SwiftTerm)
    import SwiftTerm

    /// Temporarily presents an insertion bar without losing the style received
    /// from the Host. Restore before parsing output so even repeated DECSCUSR
    /// requests are evaluated against the Host's style, not our local override.
    struct TerminalInputCursorStyle {
        private var terminalStyle: CursorStyle?

        mutating func restore(in terminal: Terminal) {
            guard let terminalStyle else { return }
            self.terminalStyle = nil
            // Restore parser state without restarting a blinking caret for
            // every output chunk. The view refreshes after presentation changes.
            terminal.options.cursorStyle = terminalStyle
        }

        mutating func update(in terminal: Terminal, isEditing: Bool) {
            guard isEditing else {
                restore(in: terminal)
                return
            }
            if terminalStyle == nil {
                terminalStyle = terminal.options.cursorStyle
            }
            terminal.setCursorStyle(.steadyBar)
        }
    }
#endif
