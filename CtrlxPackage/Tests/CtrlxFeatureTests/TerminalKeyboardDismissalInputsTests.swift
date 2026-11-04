import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@Suite("Parent keyboard-dismissal input reporting")
struct TerminalKeyboardDismissalInputsTests {
    private let target = TerminalTabFit.Target(hostID: "host", sessionName: "dev", windowID: "@1")
    private let full = ResizeTmuxPane(width: 100, height: 60, userInitiated: true)
    private let reduced = ResizeTmuxPane(width: 100, height: 20, userInitiated: true)
    private let ready = TerminalInputPresentation.State(inputEnabled: true, keyboardRequested: false)

    private func queuedFit() -> TerminalTabFit {
        var fit = TerminalTabFit()
        fit.request(target)
        #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: full) == full)
        // The earlier resize is still awaiting its Host reply when dismissal completes.
        fit.request(target, requiresHiddenKeyboard: true)
        return fit
    }

    private func take(_ fit: inout TerminalTabFit) -> ResizeTmuxPane? {
        fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: reduced)
    }

    @Test("Copy presentation cancels a handed-off Fit before the Host reply")
    func copyCancelsAfterHandoff() {
        var inputs = TerminalKeyboardDismissalInputs()
        var fit = queuedFit()
        inputs.update(ready, paneID: "%1", activePaneID: "%1", fit: &fit)
        #expect(inputs.allowsFit(paneID: "%1"))

        let copy = TerminalInputPresentation.resolve(keyboardRequested: false, isActive: true, isCopyPresented: true)
        inputs.update(copy, paneID: "%1", activePaneID: "%1", fit: &fit)
        #expect(!inputs.allowsFit(paneID: "%1"))
        #expect(take(&fit) == nil)

        inputs.update(ready, paneID: "%1", activePaneID: "%1", fit: &fit)
        #expect(inputs.allowsFit(paneID: "%1"))
        #expect(take(&fit) == nil)
    }

    @Test("Link preview cancels a handed-off Fit and stays blocked through dismissal")
    func linkCancelsAfterHandoff() throws {
        var inputs = TerminalKeyboardDismissalInputs()
        var fit = queuedFit()
        var link = TerminalLinkPresentation()
        let url = try #require(URL(string: "https://example.com"))
        let presented = link.present(url)
        #expect(presented)

        for clearsItem in [false, true] {
            if clearsItem {
                link.item = nil
            }
            let input = TerminalInputPresentation.resolve(
                keyboardRequested: false, isActive: true, isCopyPresented: false,
                isInputSuspended: link.suspendsTerminalInput
            )
            inputs.update(input, paneID: "%1", activePaneID: "%1", fit: &fit)
            #expect(!inputs.allowsFit(paneID: "%1"))
            #expect(take(&fit) == nil)
        }

        link.didDismiss()
        inputs.update(ready, paneID: "%1", activePaneID: "%1", fit: &fit)
        #expect(inputs.allowsFit(paneID: "%1"))
        #expect(take(&fit) == nil)
    }

    @Test("Missing or unmounted input is unavailable and removes a pending dismissal Fit")
    func missingAndUnmounted() {
        var inputs = TerminalKeyboardDismissalInputs()
        var fit = queuedFit()
        #expect(!inputs.allowsFit(paneID: nil))
        #expect(!inputs.allowsFit(paneID: "%1"))
        inputs.update(ready, paneID: "%1", activePaneID: "%1", fit: &fit)
        inputs.update(nil, paneID: "%1", activePaneID: "%1", fit: &fit)
        #expect(!inputs.allowsFit(paneID: "%1"))
        #expect(take(&fit) == nil)
    }

    @Test("An inactive sibling's sheet does not cancel the active pane's Fit")
    func siblingIsolation() {
        var inputs = TerminalKeyboardDismissalInputs()
        var fit = queuedFit()
        inputs.update(ready, paneID: "%1", activePaneID: "%1", fit: &fit)
        inputs.update(.init(inputEnabled: false, keyboardRequested: false), paneID: "%2", activePaneID: "%1", fit: &fit)
        #expect(inputs.allowsFit(paneID: "%1"))
        #expect(!inputs.allowsFit(paneID: "%2"))
        #expect(fit.target == target)
    }

    @Test("Private modal input reporting preserves an ordinary tab-entry request")
    func preservesEntryFit() {
        var inputs = TerminalKeyboardDismissalInputs()
        var fit = TerminalTabFit()
        fit.request(target)
        inputs.update(.init(inputEnabled: false, keyboardRequested: false), paneID: "%1", activePaneID: "%1", fit: &fit)
        #expect(fit.target == target)
    }
}
