/// One button action for both touch and accessibility; no press/release state.
public enum VoiceInputPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case finalizing

    public enum TapAction: Equatable, Sendable {
        case start
        case cancelPreparation
        case finish
        case none
    }

    public var tapAction: TapAction {
        switch self {
        case .idle: .start
        case .requestingPermission: .cancelPreparation
        case .recording: .finish
        case .finalizing: .none
        }
    }

    public var accessibilityValue: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Preparing voice input"
        case .recording: "Recording"
        case .finalizing: "Finishing transcription"
        }
    }

    public var accessibilityHint: String {
        switch self {
        case .idle: "Tap to start dictation"
        case .requestingPermission: "Tap to cancel preparation"
        case .recording: "Tap again to finish dictation"
        case .finalizing: "Wait for transcription to finish"
        }
    }
}
