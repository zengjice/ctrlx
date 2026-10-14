import Foundation
import Observation

/// A one-shot insertion authorization, not a model of the remote draft.
package struct TerminalVoiceInputCapture {
    private let context: TerminalPhraseContext
    private var consumed = false

    package init?(context: TerminalPhraseContext) {
        guard context.canSend else { return nil }
        self.context = context
    }

    package func isValid(in current: TerminalPhraseContext) -> Bool {
        !consumed && current.canSend && context.hasSameInput(as: current)
    }

    package mutating func take(_ transcript: String, in current: TerminalPhraseContext) -> String? {
        let valid = isValid(in: current)
        consumed = true
        let text = VoiceInputTextComposer.terminalTranscript(transcript)
        return valid && !text.isEmpty ? text : nil
    }
}

#if os(iOS) || os(macOS)
    @MainActor
    @Observable
    final package class TerminalVoiceInputSession {
        package let voice: VoiceInputController
        private var capture: TerminalVoiceInputCapture?

        package init() {
            self.voice = VoiceInputController()
        }

        init(voice: VoiceInputController) {
            self.voice = voice
        }

        package var isPresented: Bool {
            voice.phase != .idle
        }

        package func toggle(
            in context: TerminalPhraseContext,
            snapshot: VoiceInputContextSnapshot?, selection: VoiceCorrectionSelection?
        ) {
            if voice.phase == .idle {
                guard let capture = TerminalVoiceInputCapture(context: context) else { return }
                self.capture = capture
                voice.toggleRecording(context: snapshot, correctionSelection: selection)
                if voice.phase == .idle {
                    self.capture = nil
                }
            } else {
                validate(in: context)
                guard capture != nil else { return }
                voice.toggleRecording(context: nil, correctionSelection: nil)
            }
        }

        package func validate(in context: TerminalPhraseContext) {
            if let capture, !capture.isValid(in: context) {
                cancel()
            }
        }

        package func cancel() {
            capture = nil
            voice.cancel()
        }

        @discardableResult
        package func cancelIfPresented() -> Bool {
            guard isPresented else { return false }
            cancel()
            return true
        }

        package func deliver(in context: TerminalPhraseContext, insert: (String) -> Bool) {
            guard let transcript = voice.takeCompletedTranscript() else { return }
            var captured = capture
            capture = nil
            guard let text = captured?.take(transcript, in: context) else {
                voice.recordDelivery(enqueued: false)
                return
            }
            let enqueued = insert(text)
            voice.recordDelivery(enqueued: enqueued)
            if !enqueued {
                voice.errorMessage = "The terminal changed. Record again in the intended pane."
            }
        }
    }
#endif
