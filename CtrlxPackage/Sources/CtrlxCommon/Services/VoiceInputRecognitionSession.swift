import Foundation

/// Stateful microphone/analyzer lifetime, injectable without touching real audio.
@MainActor
protocol VoiceInputRecognitionSession: AnyObject {
    func start(
        localeIdentifier: String,
        canStart: @escaping @MainActor @Sendable () -> Bool,
        onFailure: @escaping @MainActor @Sendable (String) -> Void,
        onUpdate: @escaping @MainActor @Sendable (String) -> Void
    ) async throws
    func finish(onStage: (VoiceInputStage) -> Void) async throws -> VoiceRecognitionResult
    func cancel() async
}

enum VoiceInputStartError: LocalizedError {
    case targetChanged

    var errorDescription: String? {
        "The input window is no longer active. Record again in the intended window."
    }
}
