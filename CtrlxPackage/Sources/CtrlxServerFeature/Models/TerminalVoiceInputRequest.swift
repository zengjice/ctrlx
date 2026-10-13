import CtrlxCommon
import Foundation

/// A recording belongs to the input it started in, including focus-away-and-back.
@MainActor
struct TerminalVoiceInputRequest {
    let token: TerminalQuickActionRouter.Token
    let context: TerminalPhraseContext

    init?(router: TerminalQuickActionRouter, context: TerminalPhraseContext) {
        guard let token = router.token, router.matches(token), context.canSend else { return nil }
        self.token = token
        self.context = context
    }

    func isValid(router: TerminalQuickActionRouter, context current: TerminalPhraseContext) -> Bool {
        current.canSend && context.hasSameInput(as: current) && router.matches(token)
    }

    @discardableResult
    func insert(_ transcript: String, router: TerminalQuickActionRouter, context: TerminalPhraseContext) -> Bool {
        guard isValid(router: router, context: context) else { return false }
        let text = VoiceInputTextComposer.terminalTranscript(transcript)
        guard !text.isEmpty else { return false }
        // Only literal text, never Return. The router consumes the input revision.
        return router.send([.text(text)], to: token)
    }
}
