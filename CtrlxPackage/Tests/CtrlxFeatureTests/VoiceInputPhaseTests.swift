import Testing
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

    @Test("Starting a new dictation resets only its shadow transcript, not existing terminal text")
    func newDictation() {
        var synchronizer = TerminalInputDocumentSynchronizer()
        _ = synchronizer.advance(to: "上一段")
        synchronizer.reset()
        let delta = synchronizer.advance(to: "再检查一下")
        #expect(delta.deletionCount == 0)
        #expect(delta.insertion == "再检查一下")
        #expect(VoiceInputTextComposer.appending("再检查一下", to: "已有输入") == "已有输入 再检查一下")
    }
}
