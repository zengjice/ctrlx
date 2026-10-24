import CtrlxNetworking
import Dependencies
import Foundation
import Speech

@MainActor
enum AgentWorkflowMediaSpeech {
    static func transcribe(_ url: URL, locale: String) async throws -> String {
        @Dependency(VoiceInputAuthorization.self) var authorization
        guard await authorization.speech() == .authorized else {
            throw AgentWorkflowError("Allow Speech Recognition in Settings, or enter the transcript yourself.")
        }
        try Task.checkCancellation()
        guard let lease = VoiceInputRecordingOwnership.shared.acquire() else { throw AgentWorkflowError("Finish the current voice input before transcribing.") }
        defer { VoiceInputRecordingOwnership.shared.release(lease) }
        if #available(iOS 26.0, macOS 26.0, *) {
            return try await SpeechAnalyzerVoiceSession.transcribeRecording(at: url, localeIdentifier: locale, contextualTerms: [], accurate: true).bestAvailableTranscript
        }
        let recognition = FileRecognition()
        return try await recognition.run(url, locale: locale)
    }

    @MainActor
    final private class FileRecognition {
        private var continuation: CheckedContinuation<String, any Error>?
        private var task: SFSpeechRecognitionTask?

        func run(_ url: URL, locale: String) async throws -> String {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
                throw AgentWorkflowError("Speech recognition is unavailable for this language. Enter a transcript or try again later.")
            }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                        let final = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                        let failure = error?.localizedDescription
                        Task { @MainActor in
                            if let final {
                                self?.finish(.success(final))
                            } else if let failure {
                                self?.finish(.failure(AgentWorkflowError(failure)))
                            }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(.failure(CancellationError())) }
            }
        }

        private func finish(_ result: Result<String, any Error>) {
            let pending = continuation
            continuation = nil
            task?.cancel()
            task = nil
            pending?.resume(with: result)
        }
    }
}
