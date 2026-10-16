import AVFoundation
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Voice input preparation and interruption")
struct VoiceInputReliabilityTests {
    @Test("Revalidate the target after asynchronous preparation, before starting audio")
    func preparationTargetChanged() async {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let recorder = Recorder()
        recorder.holdPreparation = true
        let ownership = VoiceInputRecordingOwnership()
        await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { true })
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let voice = VoiceInputController(ownership: ownership, makeSession: { _, _ in recorder })
            let active = LockIsolated(true)
            voice.toggleRecording(context: nil, correctionSelection: nil, canStart: { active.value })
            await wait { recorder.preparing }
            #expect(!voice.isAwaitingAuthorization)
            active.setValue(false)
            recorder.holdPreparation = false
            await wait { voice.phase == .idle }
            #expect(!recorder.startedAudio)
            #expect(voice.errorMessage == VoiceInputStartError.targetChanged.localizedDescription)
            #expect(voice.completedTranscript == nil)
            #expect(ownership.acquire() != nil)
        }
    }

    @Test("Runtime audio or recognition failure cancels and cannot deliver partial input")
    func interruptedRecording() async {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let recorder = Recorder()
        let ownership = VoiceInputRecordingOwnership()
        await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { true })
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let voice = VoiceInputController(ownership: ownership, makeSession: { _, _ in recorder })
            voice.toggleRecording(context: nil, correctionSelection: nil)
            await wait { voice.phase == .recording }
            recorder.onFailure?("Microphone disconnected")
            await wait { recorder.cancelled }
            #expect(voice.phase == .idle)
            #expect(voice.errorMessage == "Microphone disconnected")
            #expect(voice.takeCompletedTranscript() == nil)
            #expect(ownership.acquire() != nil)
            recorder.onFailure?("Stale failure")
            #expect(voice.errorMessage == "Microphone disconnected")
        }
    }

    @Test("Language is captured once and shared with recognition and correction")
    func languageSnapshot() async {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let recorder = Recorder()
        let preferences = PreferencesService.inMemory()
        preferences.setString("zh-Hans-CN", "voiceInputLanguage")
        await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { true })
            $0[PreferencesService.self] = preferences
        } operation: {
            var correctionLocale: String?
            let voice = VoiceInputController(ownership: .init(), makeSession: { _, _ in recorder }, correct: { result, _, _, _, _ in
                correctionLocale = result.localeIdentifier
                return .init(text: result.bestAvailableTranscript, outcome: .accepted)
            })
            voice.toggleRecording(context: nil, correctionSelection: nil)
            await wait { voice.phase == .recording }
            preferences.setString("en-US", "voiceInputLanguage")
            voice.toggleRecording(context: nil, correctionSelection: nil)
            await wait { voice.phase == .idle }
            #expect(recorder.locale == "zh-Hans-CN")
            #expect(correctionLocale == "zh-Hans-CN")
        }
    }

    @Test("Audio notifications after normal stop do not cancel a later recording")
    func audioMonitorLifetime() async {
        let center = NotificationCenter()
        let monitor = VoiceInputAudioMonitor(center: center)
        let engine = AVAudioEngine()
        var failures = 0
        monitor.start(engine: engine) { _ in failures += 1 }
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        monitor.stop()
        monitor.start(engine: engine) { _ in failures += 1 }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(failures == 0)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await wait { failures == 1 }
        #expect(failures == 1)
        monitor.stop()
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for voice state")
    }

    final private class Recorder: VoiceInputRecognitionSession {
        var holdPreparation = false
        var preparing = false
        var startedAudio = false
        var cancelled = false
        var locale: String?
        var onFailure: (@MainActor @Sendable (String) -> Void)?

        func start(
            localeIdentifier: String,
            canStart: @escaping @MainActor @Sendable () -> Bool,
            onFailure: @escaping @MainActor @Sendable (String) -> Void,
            onUpdate: @escaping @MainActor @Sendable (String) -> Void
        ) async throws {
            preparing = true
            locale = localeIdentifier
            self.onFailure = onFailure
            while holdPreparation {
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            guard canStart() else { throw VoiceInputStartError.targetChanged }
            startedAudio = true
            onUpdate("只检查，不要提交。")
        }

        func finish(onStage: (VoiceInputStage) -> Void) async throws -> VoiceRecognitionResult {
            .init(primaryTranscript: "只检查，不要提交。")
        }

        func cancel() async {
            cancelled = true
        }
    }
}
