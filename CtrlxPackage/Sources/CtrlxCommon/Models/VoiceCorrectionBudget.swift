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
    static func onDeviceInput(
        recognition: VoiceRecognitionResult,
        terminalContext: String?,
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
        var context = VoiceInputContext.compacted(
            terminalContext, maximumCount: VoiceInputContext.maximumTerminalCharacterCount
        )
        while true {
            try Task.checkCancellation()
            let prompt = VoiceTranscriptCorrectionPrompt.make(recognition: evidence, terminalContext: context)
            let promptTokens = try await countTokens(prompt)
            try Task.checkCancellation()
            if fixedTokens + promptTokens <= contextSize {
                return VoiceCorrectionPreparedInput(
                    instructions: instructions, prompt: prompt, maximumResponseTokens: responseTokens
                )
            }
            if let current = context {
                let limit = current.count / 2
                context = limit < 128 ? nil : VoiceInputContext.compacted(current, maximumCount: limit)
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
