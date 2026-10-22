import Testing
@testable import CtrlxCommon
@testable import CtrlxFeature

@Suite("Tap-to-toggle voice input")
struct VoiceInputPhaseTests {
    @Test("Only idle starts a new recording; preparation can be cancelled")
    func startAndCancel() {
        #expect(VoiceInputPhase.idle.tapAction == .start)
        #expect(VoiceInputPhase.requestingPermission.tapAction == .cancelPreparation)
        #expect(VoiceInputPhase.requestingPermission.tapAction != .start)
    }

    @Test("A recording tap finishes once; taps during finalization do nothing")
    func stopAndFinalize() {
        #expect(VoiceInputPhase.recording.tapAction == .finish)
        #expect(VoiceInputPhase.finalizing.tapAction == .none)
    }

    @Test("All input surfaces describe tap, not hold/release, behavior")
    func accessibility() {
        #expect(VoiceInputPhase.idle.accessibilityHint == "Tap to start dictation")
        #expect(VoiceInputPhase.requestingPermission.accessibilityHint == "Tap to cancel preparation")
        #expect(VoiceInputPhase.recording.accessibilityHint == "Tap again to finish dictation")
        #expect(VoiceInputPhase.finalizing.accessibilityHint == "Wait for transcription to finish")
        #expect(VoiceInputPhase.recording.accessibilityValue == "Recording")
    }

    @Test("Native input fields append the new utterance without rewriting the existing draft")
    func newDictation() {
        #expect(VoiceInputTextComposer.appending("再检查一下", to: "已有输入") == "已有输入 再检查一下")
    }
}
