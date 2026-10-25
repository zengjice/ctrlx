import AVFoundation
import Dependencies
import Foundation
import Speech
import Testing
@testable import CtrlxCommon

struct SpeechRecordingAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CTRLX_SPEECH_ACCEPTANCE_AUDIO"] != nil), .timeLimit(.minutes(1)))
    @MainActor
    func convertedWorkflowRecordingReachesSystemRecognizer() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            Issue.record("This acceptance test requires SpeechAnalyzer on OS 26 or later.")
            return
        }
        // Opt in with the synthetic Chinese workflow recording; never request access or record a microphone.
        let path = try #require(ProcessInfo.processInfo.environment["CTRLX_SPEECH_ACCEPTANCE_AUDIO"])
        let url = URL(fileURLWithPath: path)
        let original = try Data(contentsOf: url)
        try #require(SFSpeechRecognizer.authorizationStatus() == .authorized)
        try #require(SpeechTranscriber.isAvailable)
        let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")))
        try #require(await SpeechTranscriber.installedLocales.contains(locale))
        let input = try AVAudioFile(forReading: url)
        try #require(input.processingFormat.sampleRate == 22_050)

        let result = try await withDependencies {
            $0[SpeechAudioFileConverter.self] = .liveValue
        } operation: {
            try await SpeechAnalyzerVoiceSession.transcribeRecording(
                at: url, localeIdentifier: locale.identifier, contextualTerms: [], accurate: true
            )
        }

        #expect(result.bestAvailableTranscript.contains("工作流"))
        #expect(result.bestAvailableTranscript.contains("蓝色"))
        #expect(result.bestAvailableTranscript.contains("绿色"))
        #expect(try Data(contentsOf: url) == original)
    }
}
