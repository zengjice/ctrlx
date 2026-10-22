import Foundation

public enum VoiceInputStage: String, Equatable, Sendable {
    case preparing
    case recording
    case finishingRecognition
    case accurateTranscription
    case providerCorrection
    case onDeviceCorrection
    case ready

    public var label: String {
        switch self {
        case .preparing: "Preparing voice input…"
        case .recording: "Listening…"
        case .finishingRecognition: "Finishing transcription…"
        case .accurateTranscription: "Refining transcription on device…"
        case .providerCorrection: "Correcting with your provider…"
        case .onDeviceCorrection: "Correcting on device…"
        case .ready: "Ready to insert"
        }
    }
}

/// Monotonic stage timing. Contains no audio, transcript, paths or credentials.
struct VoiceInputTiming: Sendable {
    private(set) var stage: VoiceInputStage
    private var startedAt: ContinuousClock.Instant

    init(stage: VoiceInputStage, at now: ContinuousClock.Instant = .now) {
        self.stage = stage
        self.startedAt = now
    }

    mutating func advance(to next: VoiceInputStage, at now: ContinuousClock.Instant = .now) -> Duration {
        let elapsed = startedAt.duration(to: now)
        stage = next
        startedAt = now
        return elapsed
    }
}
