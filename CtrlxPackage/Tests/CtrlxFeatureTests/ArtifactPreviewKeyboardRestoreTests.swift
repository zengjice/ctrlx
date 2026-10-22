import Testing
@testable import CtrlxFeature

@Suite("Artifact preview keyboard restore")
struct ArtifactPreviewKeyboardRestoreTests {
    @Test("A preview chain restores the keyboard state captured before its first preview")
    func keepsTheFirstSnapshot() {
        var restore = ArtifactPreviewKeyboardRestore()
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: true)
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: false)

        #expect(restore.consume(terminalIsVisible: true, activePaneID: "%1") == true)
        #expect(restore.consume(terminalIsVisible: true, activePaneID: "%1") == nil)
    }

    @Test("A hidden keyboard is a valid captured state")
    func preservesHiddenKeyboard() {
        var restore = ArtifactPreviewKeyboardRestore()
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: false)

        #expect(restore.consume(terminalIsVisible: true, activePaneID: "%1") == false)
    }

    @Test("Leaving the preview chain discards the snapshot before the next preview")
    func leavingTheChainStartsFresh() {
        var restore = ArtifactPreviewKeyboardRestore()
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: true)
        restore.discard()
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: false)

        #expect(restore.consume(terminalIsVisible: true, activePaneID: "%1") == false)
    }

    @Test("Cancelling a file-link handoff while another tab is visible clears the snapshot")
    func cancelledHandoffStartsFresh() {
        var restore = ArtifactPreviewKeyboardRestore()
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: true)

        #expect(restore.consume(terminalIsVisible: false, activePaneID: "%1") == nil)

        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: false)
        #expect(restore.consume(terminalIsVisible: true, activePaneID: "%1") == false)
    }

    @Test("The keyboard is not restored after leaving the terminal or switching panes", arguments: [
        (false, "%1"), (true, "%2"),
    ])
    func requiresTheOriginalVisiblePane(terminalIsVisible: Bool, activePaneID: String) {
        var restore = ArtifactPreviewKeyboardRestore()
        restore.captureIfNeeded(paneID: "%1", keyboardIsActive: true)

        #expect(restore.consume(terminalIsVisible: terminalIsVisible, activePaneID: activePaneID) == nil)
        #expect(restore.consume(terminalIsVisible: true, activePaneID: "%1") == nil)
    }
}
