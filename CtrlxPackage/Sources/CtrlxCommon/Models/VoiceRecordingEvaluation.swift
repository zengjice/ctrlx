import Foundation

struct VoiceRecordingEvaluationReport: Codable, Sendable {
    struct Stage: Codable, Identifiable, Sendable {
        let name: String
        let transcript: String
        let alternatives: [String]
        let elapsedSeconds: Double
        let unmatchedReferenceCharacters: Int
        let missingTerms: [String]
        let preservesIntentMarkers: Bool
        let preservesLiterals: Bool
        var id: String {
            name
        }

        init(
            name: String,
            transcript: String,
            alternatives: [String] = [],
            elapsedSeconds: Double,
            reference: String,
            terms: [String]
        ) {
            self.name = name
            self.transcript = transcript
            self.alternatives = alternatives
            self.elapsedSeconds = elapsedSeconds
            let difference = VoiceTranscriptFidelity.normalized(transcript)
                .difference(from: VoiceTranscriptFidelity.normalized(reference))
            self.unmatchedReferenceCharacters = difference.removals.count
            self.missingTerms = terms.filter { !transcript.localizedCaseInsensitiveContains($0) }
            self.preservesIntentMarkers = VoiceTranscriptFidelity.preservesIntentMarkers(transcript, from: reference)
            self.preservesLiterals = VoiceTranscriptCorrectionPolicy.preservesLiterals(transcript, from: reference)
        }
    }

    let audioFileName: String
    let localeIdentifier: String
    let systemVersion: String
    let reference: String
    let context: String?
    let vocabulary: [String]
    let configuredCorrectionModel: String?
    let correctionModel: String?
    let correctionOutcome: String
    let correctionDidFallback: Bool
    let usedLiveFallback: Bool
    let stages: [Stage]

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

#if os(iOS) || os(macOS)
    import Dependencies

    @MainActor
    enum VoiceRecordingEvaluation {
        typealias Recognize = @MainActor (URL, String, [String], Bool, String) async throws -> VoiceRecognitionResult
        typealias Correct = @MainActor (VoiceRecognitionResult, [String], VoiceInputContextSnapshot?, VoiceCorrectionSelection?) async -> VoiceCorrectionResult

        /// Replays one file through the production progressive and accurate recognizers.
        /// Timings measure file processing, not microphone latency or perceived live latency.
        static func run(
            file: URL, reference: String, localeIdentifier: String,
            context: String? = nil, includeCorrection: Bool = false,
            selection: VoiceCorrectionSelection? = nil,
            onStage: (String) -> Void = { _ in },
            recognize: Recognize = { url, locale, terms, accurate, live in
                guard #available(iOS 26.0, macOS 26.0, *) else { throw EvaluationError.requiresModernSpeech }
                return try await SpeechAnalyzerVoiceSession.transcribeRecording(
                    at: url, localeIdentifier: locale, contextualTerms: terms, accurate: accurate, liveTranscript: live
                )
            },
            correct: Correct = { recognition, terms, context, selection in
                await VoiceTranscriptCorrector.correct(
                    recognition,
                    contextualTerms: terms,
                    terminalContext: context,
                    providerSelection: selection
                )
            }
        ) async throws -> VoiceRecordingEvaluationReport {
            guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reference.count <= 4_000 else {
                throw EvaluationError.invalidReference
            }
            try Task.checkCancellation()
            @Dependency(VoiceInputAuthorization.self) var authorization
            guard await authorization.speech() == .authorized else { throw EvaluationError.speechPermission }
            try Task.checkCancellation()
            guard let lease = VoiceInputRecordingOwnership.shared.acquire() else { throw EvaluationError.busy }
            defer { VoiceInputRecordingOwnership.shared.release(lease) }

            let snapshot = context.map { VoiceInputContextSnapshot(terminalText: $0) }
            let vocabulary = VoiceInputVocabulary.terms(for: snapshot)
            let expectedTerms = vocabulary.filter { reference.localizedCaseInsensitiveContains($0) }
            var stages: [VoiceRecordingEvaluationReport.Stage] = []
            let clock = ContinuousClock()
            onStage("Replaying live recognizer…")
            var start = clock.now
            let live = try await recognize(file, localeIdentifier, vocabulary, false, "")
            try Task.checkCancellation()
            stages.append(.init(
                name: "Live recognizer replay",
                transcript: live.bestAvailableTranscript,
                alternatives: live.alternativeTranscripts,
                elapsedSeconds: seconds(start.duration(to: clock.now)),
                reference: reference,
                terms: expectedTerms
            ))

            onStage("Running accurate transcription…")
            start = clock.now
            let accurate = try await recognize(file, localeIdentifier, vocabulary, true, live.bestAvailableTranscript)
            try Task.checkCancellation()
            let recognition = VoiceRecognitionResult(
                primaryTranscript: accurate.primaryTranscript,
                alternativeTranscripts: accurate.alternativeTranscripts,
                liveTranscript: live.bestAvailableTranscript,
                localeIdentifier: localeIdentifier
            )
            stages.append(.init(
                name: "Accurate transcription",
                transcript: recognition.primaryTranscript,
                alternatives: recognition.alternativeTranscripts,
                elapsedSeconds: seconds(start.duration(to: clock.now)),
                reference: reference,
                terms: expectedTerms
            ))
            stages.append(.init(
                name: "Selected transcription",
                transcript: recognition.bestAvailableTranscript,
                elapsedSeconds: 0,
                reference: reference,
                terms: expectedTerms
            ))

            var outcome = "notRun"
            var correctionModel: String?
            var correctionDidFallback = false
            if includeCorrection {
                onStage("Correcting transcription…")
                start = clock.now
                let corrected = await correct(recognition, vocabulary, snapshot, selection)
                try Task.checkCancellation()
                outcome = String(describing: corrected.outcome)
                correctionModel = corrected.modelID
                correctionDidFallback = corrected.didFallback
                stages.append(.init(
                    name: "Correction",
                    transcript: corrected.text,
                    elapsedSeconds: seconds(start.duration(to: clock.now)),
                    reference: reference,
                    terms: expectedTerms
                ))
            }
            return .init(
                audioFileName: file.lastPathComponent,
                localeIdentifier: localeIdentifier,
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                reference: reference,
                context: context,
                vocabulary: vocabulary,
                configuredCorrectionModel: includeCorrection ? (selection?.modelID ?? "on-device") : nil,
                correctionModel: correctionModel,
                correctionOutcome: outcome,
                correctionDidFallback: correctionDidFallback,
                usedLiveFallback: recognition.prefersLiveTranscript,
                stages: stages
            )
        }

        private static func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1E18
        }

        private enum EvaluationError: LocalizedError {
            case requiresModernSpeech
            case invalidReference
            case speechPermission
            case busy
            var errorDescription: String? {
                switch self {
                case .requiresModernSpeech: "Recording evaluation requires iOS 26 or macOS 26."
                case .invalidReference: "Enter a reference transcript of 1–4,000 characters."
                case .speechPermission: "Allow Speech Recognition in Settings to evaluate a recording."
                case .busy: "Finish voice input or the current recording evaluation first."
                }
            }
        }
    }
#endif
