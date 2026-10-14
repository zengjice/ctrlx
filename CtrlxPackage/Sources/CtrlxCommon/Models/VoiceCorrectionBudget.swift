import Foundation

struct VoiceCorrectionPreparedInput {
    let instructions: String
    let prompt: String
    let maximumResponseTokens: Int
}

enum VoiceCorrectionBudget {
    static func responseTokens(for sourceTokens: Int) -> Int {
        max(256, sourceTokens * 2 + 64)
    }

    static func providerResponseTokens(for transcript: String) -> Int? {
        let count = max(512, responseTokens(for: transcript.utf8.count))
        return count <= 8_192 ? count : nil
    }

    /// Reserve the complete utterance and response first. Background context and
    /// phonetic hints can be dropped; the user's utterance must never be truncated.
    nonisolated(nonsending) static func onDeviceInput(
        recognition: VoiceRecognitionResult,
        terminalContext: VoiceInputContextSnapshot?,
        contextualTerms: [String],
        localeIdentifier: String,
        contextSize: Int,
        countTokens: (String) async throws -> Int
    ) async throws -> VoiceCorrectionPreparedInput? {
        try Task.checkCancellation()
        let instructions = VoiceTranscriptCorrectionPrompt.instructions(
            localeIdentifier: localeIdentifier, contextualTerms: contextualTerms
        )
        let instructionTokens = try await countTokens(instructions)
        let sourceTokens = try await countTokens(recognition.bestAvailableTranscript)
        let responseTokens = responseTokens(for: sourceTokens)
        // Includes message framing and differences between separately tokenized sections.
        let fixedTokens = instructionTokens + responseTokens + 128
        guard fixedTokens < contextSize else { return nil }

        var evidence = recognition
        var contextLimit = terminalContext?.formatted()?.count ?? 0
        while true {
            try Task.checkCancellation()
            let prompt = VoiceTranscriptCorrectionPrompt.make(
                recognition: evidence, terminalContext: terminalContext, maximumContextCount: contextLimit
            )
            let promptTokens = try await countTokens(prompt)
            try Task.checkCancellation()
            if fixedTokens + promptTokens <= contextSize {
                return VoiceCorrectionPreparedInput(
                    instructions: instructions, prompt: prompt, maximumResponseTokens: responseTokens
                )
            }
            if contextLimit > 0 {
                contextLimit /= 2
                if contextLimit < 128 {
                    contextLimit = 0
                }
            } else if !evidence.alternativeTranscripts.isEmpty || !evidence.liveTranscript.isEmpty {
                evidence = VoiceRecognitionResult(
                    primaryTranscript: recognition.bestAvailableTranscript,
                    diagnosticID: recognition.diagnosticID
                )
            } else {
                return nil
            }
        }
    }
}
