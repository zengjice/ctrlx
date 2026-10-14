import Foundation
import OSLog

enum VoiceInputDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jicezeng.ctrlx",
        category: "VoiceInput"
    )

    static func recognizer(_ name: String, stage: String, locale: Locale, id: String) {
        logger.debug(
            "[\(shortID(id), privacy: .public)] \(stage, privacy: .public) recognizer=\(name, privacy: .public) locale=\(locale.identifier, privacy: .public)"
        )
    }

    static func recognitionResult(_ result: VoiceRecognitionResult) {
        logger.debug(
            "[\(shortID(result.diagnosticID), privacy: .public)] transcription complete alternatives=\(result.alternativeTranscripts.count, privacy: .public) primary=\(result.primaryTranscript, privacy: .private) live=\(result.liveTranscript, privacy: .private) candidates=\(String(describing: result.alternativeTranscripts), privacy: .private)"
        )
    }

    static func recognitionFallback(error: Error, id: String) {
        logger.error(
            "[\(shortID(id), privacy: .public)] accurate transcription failed; using live result: \(error.localizedDescription, privacy: .public)"
        )
    }

    static func correctionStarted(
        result: VoiceRecognitionResult,
        hasTerminalContext: Bool
    ) {
        logger.debug(
            "[\(shortID(result.diagnosticID), privacy: .public)] correction started alternatives=\(result.alternativeTranscripts.count, privacy: .public) liveEvidence=\(!result.liveTranscript.isEmpty, privacy: .public) terminalContext=\(hasTerminalContext, privacy: .public)"
        )
    }

    static func correctionModel(locale: Locale, id: String) {
        logger.debug(
            "[\(shortID(id), privacy: .public)] corrector=SystemLanguageModel useCase=general locale=\(locale.identifier, privacy: .public)"
        )
    }

    static func correctionProvider(provider: String, model: String, id: String) {
        logger.notice(
            "[\(shortID(id), privacy: .public)] corrector=BYOK provider=\(provider, privacy: .public) model=\(model, privacy: .public)"
        )
    }

    static func correctionFinished(
        original: String,
        result: VoiceCorrectionAttempt,
        elapsed: Duration,
        id: String
    ) {
        switch result {
        case let .accepted(corrected):
            logger.notice(
                "[\(shortID(id), privacy: .public)] correction accepted changed=\(corrected != original, privacy: .public) elapsed=\(elapsed.description, privacy: .public)"
            )
        case let .rejected(reason):
            logger.notice(
                "[\(shortID(id), privacy: .public)] correction rejected reason=\(reason.rawValue, privacy: .public) elapsed=\(elapsed.description, privacy: .public); preserving transcription"
            )
        case .unavailable:
            break
        }
    }

    static func stageFinished(_ stage: VoiceInputStage, elapsed: Duration, id: String) {
        logger.notice("[\(shortID(id), privacy: .public)] stage=\(stage.rawValue, privacy: .public) elapsed=\(elapsed.description, privacy: .public)")
    }

    static func delivery(enqueued: Bool, id: String) {
        logger.notice("[\(shortID(id), privacy: .public)] terminal input enqueued=\(enqueued, privacy: .public)")
    }

    static func correctionSkipped(reason: String, id: String) {
        logger.notice(
            "[\(shortID(id), privacy: .public)] correction skipped: \(reason, privacy: .public)"
        )
    }

    static func correctionFailed(error: Error, id: String) {
        logger.error(
            "[\(shortID(id), privacy: .public)] correction failed: \(error.localizedDescription, privacy: .public)"
        )
    }

    private static func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }
}
