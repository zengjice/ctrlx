/// One button action for both touch and accessibility; no press/release state.
enum VoiceInputPhase: Equatable {
    case idle
    case requestingPermission
    case recording
    case finalizing

    enum TapAction: Equatable {
        case start, cancelPreparation, finish, none
    }

    var tapAction: TapAction {
        switch self {
        case .idle: .start
        case .requestingPermission: .cancelPreparation
        case .recording: .finish
        case .finalizing: .none
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle: "Ready"
        case .requestingPermission: "Preparing voice input"
        case .recording: "Recording"
        case .finalizing: "Finishing transcription"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .idle: "Tap to start dictation"
        case .requestingPermission: "Tap to cancel preparation"
        case .recording: "Tap again to finish dictation"
        case .finalizing: "Wait for transcription to finish"
        }
    }
}
