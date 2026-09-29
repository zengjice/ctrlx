/// A completed single tap has exactly one owner. Multi-tap/selection gesture
/// arbitration happens before this policy; links remain local in either mode.
enum TerminalContentTapRouting {
    enum Action: Equatable {
        case ignore
        case openLink
        case mouseClick
        case cursorNavigation
    }

    static func action(
        selectionActive: Bool,
        hasLink: Bool,
        canSendInput: Bool,
        mouseModeActive: Bool,
        isLiveScreen: Bool
    ) -> Action {
        guard !selectionActive else { return .ignore }
        if hasLink { return .openLink }
        guard canSendInput, isLiveScreen else { return .ignore }
        return mouseModeActive ? .mouseClick : .cursorNavigation
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
            guard terminal.mouseMode != .off,
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
            if terminal.mouseMode != .x10 { send(release: true) }
            return true
        }
    }
#endif
