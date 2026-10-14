import Foundation

/// Stateful microphone/analyzer lifetime, injectable without touching real audio.
@MainActor
protocol VoiceInputRecognitionSession: AnyObject {
    func start(onUpdate: @escaping @MainActor @Sendable (String) -> Void) async throws
    func finish(onStage: (VoiceInputStage) -> Void) async throws -> VoiceRecognitionResult
    func cancel() async
}
