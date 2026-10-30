import Foundation

/// In-memory evidence for one completed recording; encoded only on an explicit debug copy.
struct VoiceInputDebugReport: Encodable, Sendable {
    struct Transcription: Encodable, Sendable {
        let original: String
        let primary: String
        let live: String
        let alternatives: [String]
    }

    let diagnosticID: String
    let localeIdentifier: String
    let transcription: Transcription
    let context: VoiceInputContextSnapshot
    let contextualTerms: [String]
    let correction: VoiceCorrectionResult
    let insertedText: String

    init(
        recognition: VoiceRecognitionResult, context: VoiceInputContextSnapshot?,
        contextualTerms: [String], correction: VoiceCorrectionResult, insertedText: String
    ) {
        self.diagnosticID = recognition.diagnosticID
        self.localeIdentifier = recognition.localeIdentifier
        self.transcription = Transcription(
            original: recognition.bestAvailableTranscript,
            primary: recognition.primaryTranscript, live: recognition.liveTranscript,
            alternatives: recognition.alternativeTranscripts
        )
        self.context = context ?? .init()
        self.contextualTerms = contextualTerms
        self.correction = correction
        self.insertedText = insertedText
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(self), as: UTF8.self)
    }
}
