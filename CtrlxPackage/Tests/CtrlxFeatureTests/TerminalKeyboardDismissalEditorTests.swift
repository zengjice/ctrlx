import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@Suite("Terminal keyboard dismissal while editing")
struct TerminalKeyboardDismissalEditorTests {
    private func phrase() -> TerminalPhraseContext {
        TerminalPhraseContext(
            hostID: "host",
            paneID: "%1",
            inputRevision: 0,
            isConnected: true,
            isInputAvailable: true
        )
    }

    @Test("An editor cancels a parent dismissal Fit queued behind a Host reply", arguments: [false, true])
    func editorCancelsQueuedDismissal(customButton: Bool) {
        let target = TerminalTabFit.Target(hostID: "host", sessionName: "dev", windowID: "@1")
        let full = ResizeTmuxPane(width: 100, height: 60, userInitiated: true)
        let editorViewport = ResizeTmuxPane(width: 100, height: 20, userInitiated: true)
        var fit = TerminalTabFit()
        fit.request(target)
        // The previous resize has been dispatched but has not received its Host reply.
        #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: full) == full)
        fit.request(target, requiresHiddenKeyboard: true)

        var presentation = TerminalQuickActionPresentation()
        presentation.show(customButton ? .addCustomButton(phrase()) : .phrases(phrase()))
        if !customButton {
            presentation.isEditingPhrase = true
        }
        let suspension = TerminalInputSuspension(external: false, quickActionEditor: presentation.suspendsTerminalInput)
        let input = TerminalInputPresentation.resolve(
            keyboardRequested: false, isActive: true, isCopyPresented: false,
            isInputSuspended: suspension.suspendsInput
        )
        #expect(input.keyboardRequested == false)
        #expect(input.allowsKeyboardDismissalFit == false)
        if !input.allowsKeyboardDismissalFit {
            fit.cancelKeyboardDismissal()
        }

        // Releasing the resize guard while the editor's keyboard is visible sends nothing.
        #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: editorViewport) == nil)
        presentation.dismiss()
        #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: full) == nil)
    }

    @Test("Browsing quick actions preserves a queued keyboard-dismissal Fit")
    func browsingKeepsQueuedDismissal() {
        for panel in [TerminalQuickActionPresentation.Panel.phrases(phrase()), .commandsUnavailable(phrase())] {
            var presentation = TerminalQuickActionPresentation()
            presentation.show(panel)
            let input = TerminalInputPresentation.resolve(
                keyboardRequested: false, isActive: true, isCopyPresented: false,
                isInputSuspended: presentation.suspendsTerminalInput
            )
            #expect(input.allowsKeyboardDismissalFit)
            let target = TerminalTabFit.Target(hostID: "host", sessionName: "dev", windowID: "@1")
            let grid = ResizeTmuxPane(width: 100, height: 60, userInitiated: true)
            var fit = TerminalTabFit()
            fit.request(target, requiresHiddenKeyboard: true)
            if !input.allowsKeyboardDismissalFit {
                fit.cancelKeyboardDismissal()
            }
            #expect(fit.takeRequest(for: target, isAvailable: true, isPresentationReady: true, measuredRequest: grid) == grid)
        }
    }
}
