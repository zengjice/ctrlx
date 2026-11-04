import Testing
@testable import CtrlxFeature

@Suite("Terminal input presentation")
struct TerminalInputPresentationTests {
    @Test("An active terminal keeps shortcuts available without the keyboard")
    func activeTerminalWithoutKeyboard() {
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: false,
            isActive: true,
            isCopyPresented: false
        ) == TerminalInputPresentation.State(
            inputEnabled: true,
            keyboardRequested: false
        ))
    }

    @Test("Requesting the keyboard keeps both keyboard and shortcuts available")
    func activeTerminalWithKeyboard() {
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: true,
            isActive: true,
            isCopyPresented: false
        ) == TerminalInputPresentation.State(
            inputEnabled: true,
            keyboardRequested: true
        ))
    }

    @Test("The copy sheet suppresses all terminal input")
    func copySheetSuppressesInput() {
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: false,
            isActive: true,
            isCopyPresented: true
        ) == TerminalInputPresentation.State(
            inputEnabled: false,
            keyboardRequested: false
        ))
    }

    @Test("Inactive terminals never accept input")
    func inactiveTerminal() {
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: true,
            isActive: false,
            isCopyPresented: false
        ) == TerminalInputPresentation.State(
            inputEnabled: false,
            keyboardRequested: false
        ))
    }

    @Test("Phrase editors suspend native input without losing keyboard intent", arguments: [false, true])
    func phraseEditor(keyboardRequested: Bool) {
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true,
            isCopyPresented: false, isInputSuspended: true
        ) == TerminalInputPresentation.State(inputEnabled: false, keyboardRequested: false))
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true,
            isCopyPresented: false, isInputSuspended: false
        ) == TerminalInputPresentation.State(inputEnabled: true, keyboardRequested: keyboardRequested))
        // Dismissing the editor must not activate another pane or bypass Copy.
        for isCopyPresented in [false, true] {
            #expect(TerminalInputPresentation.resolve(
                keyboardRequested: keyboardRequested, isActive: false,
                isCopyPresented: isCopyPresented, isInputSuspended: false
            ) == TerminalInputPresentation.State(inputEnabled: false, keyboardRequested: false))
        }
        #expect(TerminalInputPresentation.resolve(
            keyboardRequested: keyboardRequested, isActive: true,
            isCopyPresented: true, isInputSuspended: false
        ) == TerminalInputPresentation.State(inputEnabled: false, keyboardRequested: false))
    }
}

@Suite("Terminal initial tail presentation")
struct TerminalInitialTailPresentationPolicyTests {
    @Test("Presentation waits for both a window and usable bounds")
    func waitsForNativeLayout() {
        var policy = TerminalInitialTailPresentationPolicy()
        policy.request()

        let beforeAttachment = policy.consumeIfReady(
            isAttachedToWindow: false,
            hasUsableBounds: true
        )
        let beforeUsableBounds = policy.consumeIfReady(
            isAttachedToWindow: true,
            hasUsableBounds: false
        )
        let afterNativeLayout = policy.consumeIfReady(
            isAttachedToWindow: true,
            hasUsableBounds: true
        )

        #expect(!beforeAttachment)
        #expect(!beforeUsableBounds)
        #expect(afterNativeLayout)
    }

    @Test("One request is consumed by exactly one stable layout")
    func consumesOnce() {
        var policy = TerminalInitialTailPresentationPolicy()
        policy.request()

        let firstConsumption = policy.consumeIfReady(
            isAttachedToWindow: true,
            hasUsableBounds: true
        )
        let duplicateConsumption = policy.consumeIfReady(
            isAttachedToWindow: true,
            hasUsableBounds: true
        )

        policy.request()
        let secondConsumption = policy.consumeIfReady(
            isAttachedToWindow: true,
            hasUsableBounds: true
        )

        #expect(firstConsumption)
        #expect(!duplicateConsumption)
        #expect(secondConsumption)
    }
}

@Suite("Terminal keyboard dismissal Fit")
struct TerminalKeyboardDismissalFitTests {
    @Test("A measurement before keyboard dismissal cannot trigger Fit")
    func waitsForKeyboardAndViewport() {
        var fit = TerminalKeyboardDismissalFit()
        fit.requestKeyboard(false)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
        #expect(fit.keyboardDidHide() == true)
        #expect(fit.consumeIfReady(hasViewport: false) == false)
        #expect(fit.consumeIfReady(hasViewport: true) == true)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
    }

    @Test("Passive keyboard notifications and geometry cannot arm Fit")
    func requiresExplicitDismissal() {
        var fit = TerminalKeyboardDismissalFit()
        #expect(fit.keyboardDidHide() == false)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
        fit.requestKeyboard(true)
        #expect(fit.keyboardDidHide() == false)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
    }

    @Test("Reopening the keyboard cancels before or after dismissal", arguments: [false, true])
    func reopeningCancels(dismissed: Bool) {
        var fit = TerminalKeyboardDismissalFit()
        fit.requestKeyboard(false)
        if dismissed {
            #expect(fit.keyboardDidHide() == true)
        }
        fit.requestKeyboard(true)
        #expect(fit.keyboardDidHide() == false)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
    }

    @Test("Leaving or suspending the input cancels the pending Fit", arguments: [false, true])
    func cancellation(dismissed: Bool) {
        var fit = TerminalKeyboardDismissalFit()
        fit.requestKeyboard(false)
        if dismissed {
            #expect(fit.keyboardDidHide() == true)
        }
        fit.cancel()
        #expect(fit.keyboardDidHide() == false)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
    }

    @Test("Repeated completion notifications do not reset a ready request")
    func repeatedNotifications() {
        var fit = TerminalKeyboardDismissalFit()
        fit.requestKeyboard(false)
        #expect(fit.keyboardDidHide() == true)
        #expect(fit.keyboardDidHide() == false)
        #expect(fit.consumeIfReady(hasViewport: true) == true)
        #expect(fit.keyboardDidHide() == false)
        #expect(fit.consumeIfReady(hasViewport: true) == false)
    }
}
