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

    @Test("Phrase panels suspend native input without losing keyboard intent", arguments: [false, true])
    func phrasePanel(keyboardRequested: Bool) {
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
