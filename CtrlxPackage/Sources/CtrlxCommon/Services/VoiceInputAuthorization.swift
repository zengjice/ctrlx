#if os(iOS) || os(macOS)
    import AVFoundation
    import Dependencies
    import DependenciesMacros
    import Speech

    @DependencyClient
    struct VoiceInputAuthorization {
        var speech: @Sendable () async -> SFSpeechRecognizerAuthorizationStatus = { .denied }
        var microphone: @Sendable () async -> Bool = { false }
    }

    extension VoiceInputAuthorization: DependencyKey {
        static let testValue = Self()
        static let liveValue = Self(
            speech: {
                // TCC completions are not MainActor callbacks.
                await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
            },
            microphone: {
                await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }
        )
    }
#endif
