import CtrlxCommon
import Testing

@Suite("Terminal bottom anchor policy")
struct TerminalBottomAnchorPolicyTests {
    @Test("Initial layout starts at the bottom")
    func initialLayoutAnchors() {
        let policy = TerminalBottomAnchorPolicy()

        #expect(policy.targetOffset(maximumOffset: 120) == 120)
    }

    @Test("Automatic intermediate offsets cannot break startup anchoring")
    func intermediateLayoutOffsetsKeepFollowing() {
        let policy = TerminalBottomAnchorPolicy()

        #expect(policy.targetOffset(maximumOffset: 120) == 120)
        // UIKit may temporarily place the viewport between its old and new
        // bottom while safe-area and representable layouts settle. The policy
        // no longer infers user intent from that transient offset.
        #expect(policy.targetOffset(maximumOffset: 180) == 180)
    }

    @Test("Manual scrolling is preserved")
    func manualScrollIsPreserved() {
        var policy = TerminalBottomAnchorPolicy()
        policy.userWillBeginScrolling()
        policy.userDidEndScrolling(currentOffset: 60, maximumOffset: 180)

        #expect(policy.targetOffset(maximumOffset: 220) == nil)
    }

    @Test("Returning to the bottom resumes anchoring")
    func returningToBottomResumesAnchoring() {
        var policy = TerminalBottomAnchorPolicy()
        policy.userWillBeginScrolling()
        policy.userDidEndScrolling(currentOffset: 180, maximumOffset: 180)

        #expect(policy.targetOffset(maximumOffset: 220) == 220)
    }

    @Test("A drag pauses anchoring until it finishes")
    func activeDragPausesAnchoring() {
        var policy = TerminalBottomAnchorPolicy()
        policy.userWillBeginScrolling()

        #expect(policy.targetOffset(maximumOffset: 180) == nil)
    }

    @Test("Explicit bottom requests override manual scrolling")
    func forcedAnchorOverridesManualScroll() {
        var policy = TerminalBottomAnchorPolicy()
        policy.userWillBeginScrolling()
        policy.userDidEndScrolling(currentOffset: 40, maximumOffset: 180)
        policy.requestScrollToBottom()

        #expect(policy.targetOffset(maximumOffset: 180) == 180)
    }

    @Test("Inset-adjusted negative bottom offsets are preserved")
    func negativeBottomOffsetIsPreserved() {
        let policy = TerminalBottomAnchorPolicy()

        #expect(policy.targetOffset(maximumOffset: -12) == -12)
    }

    @Test("A first-row Shell prompt is not hidden by a tall grid", arguments: [638.0, 600.0, 400.0])
    func sparseShell(viewportHeight: Double) {
        let policy = TerminalBottomAnchorPolicy()
        let gridHeight = 57.0 * 13
        let offset = policy.targetOffset(maximumOffset: gridHeight - viewportHeight, cursorTop: 0)
        #expect(offset == 0)
    }

    @Test("A low cursor and fullscreen fallback keep the existing bottom position")
    func lowCursorAndFullscreen() {
        let policy = TerminalBottomAnchorPolicy()
        #expect(policy.targetOffset(maximumOffset: 103, cursorTop: 56 * 13) == 103)
        #expect(policy.targetOffset(maximumOffset: 103, cursorTop: nil) == 103)
    }

    @Test("Cursor placement uses canvas coordinates and adjusted top insets")
    func canvasAndInsets() {
        let policy = TerminalBottomAnchorPolicy()
        #expect(policy.targetOffset(maximumOffset: 103, cursorTop: 39, topInset: 12) == 27)
        #expect(policy.targetOffset(maximumOffset: 103, cursorTop: 0, topInset: 12) == -12)
        #expect(policy.targetOffset(maximumOffset: -12, cursorTop: 80, topInset: 12) == -12)
    }

    @Test("Layout cannot reveal a cursor while a user owns history or a drag")
    func cursorDoesNotOverrideUserScrolling() {
        var policy = TerminalBottomAnchorPolicy()
        policy.userWillBeginScrolling()
        #expect(policy.targetOffset(maximumOffset: 103, cursorTop: 0) == nil)
        policy.userDidEndScrolling(currentOffset: 30, maximumOffset: 103)
        #expect(policy.targetOffset(maximumOffset: 200, cursorTop: 0) == nil)
        policy.requestScrollToBottom()
        #expect(policy.targetOffset(maximumOffset: 200, cursorTop: 0) == 0)
    }
}
