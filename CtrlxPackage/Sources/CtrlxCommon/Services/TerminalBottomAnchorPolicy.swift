import Foundation

/// Keeps the live cursor (or a fullscreen terminal's bottom) visible across layout changes
/// without overriding a user's deliberate scroll into history.
package struct TerminalBottomAnchorPolicy: Equatable, Sendable {
    package static let tolerance = 1.0

    /// Follow the live terminal tail until the user explicitly takes ownership
    /// of the viewport by dragging it. Layout transitions are not user intent:
    /// safe-area, keyboard, and Auto Layout passes may all expose temporary
    /// offsets while the final viewport is still settling.
    private var followsBottom = true

    package init() { }

    /// Returns a visible live-tail offset while the viewport follows live output.
    /// A nil result means the user owns the scroll position.
    package func targetOffset(
        maximumOffset: Double,
        cursorTop: Double? = nil,
        topInset: Double = 0
    ) -> Double? {
        guard followsBottom else { return nil }
        guard let cursorTop else { return maximumOffset }
        // A quiet Shell can have its prompt at the top of a tall grid. Do not
        // hide it just to show the empty rows below it.
        return max(-topInset, min(maximumOffset, cursorTop - topInset))
    }

    package mutating func userWillBeginScrolling() {
        followsBottom = false
    }

    /// Resume following only when the user deliberately returns to the tail.
    package mutating func userDidEndScrolling(
        currentOffset: Double,
        maximumOffset: Double
    ) {
        followsBottom = abs(currentOffset - maximumOffset) <= Self.tolerance
    }

    package mutating func requestScrollToBottom() {
        followsBottom = true
    }
}
