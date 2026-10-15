#if os(iOS) || os(macOS)
    import Dependencies
    import DependenciesMacros
    import Foundation
    #if canImport(FoundationModels)
        import FoundationModels
    #endif

    enum VoiceCorrectionAvailability: Equatable, Sendable {
        case available
        case unavailable(String)

        var isAvailable: Bool {
            self == .available
        }

        var label: String {
            switch self {
            case .available: "Available"
            case let .unavailable(reason): reason
            }
        }
    }

    @DependencyClient
    struct VoiceCorrectionAvailabilityClient {
        var onDevice: @Sendable () -> VoiceCorrectionAvailability = { .unavailable("Not checked") }
    }

    extension VoiceCorrectionAvailabilityClient: DependencyKey {
        static let testValue = Self(onDevice: { .unavailable("Unavailable in tests") })
        static let liveValue = Self(onDevice: {
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
                    switch model.availability {
                    case .available:
                        let locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
                        return model.supportsLocale(locale)
                            ? .available : .unavailable("Current language is not supported")
                    case let .unavailable(reason):
                        switch reason {
                        case .deviceNotEligible: return .unavailable("Apple Intelligence is not supported on this device")
                        case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence is not enabled")
                        case .modelNotReady: return .unavailable("Apple Intelligence model is not ready")
                        @unknown default: return .unavailable("Apple Intelligence is unavailable")
                        }
                    }
                }
            #endif
            return .unavailable("Requires iOS 26 or macOS 26 and Apple Intelligence")
        })
    }
#endif
