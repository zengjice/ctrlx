import Foundation

public enum VoiceInputTextComposer {
    /// Literal terminal input must never synthesize Return, Tab or escape keys.
    public static func terminalTranscript(_ transcript: String) -> String {
        let singleLine = transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(singleLine.unicodeScalars.filter { $0.properties.generalCategory != .control })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func appending(_ transcript: String, to baseText: String) -> String {
        let trimmedTranscript = terminalTranscript(transcript)
        guard !trimmedTranscript.isEmpty else { return baseText }
        guard !baseText.isEmpty else { return trimmedTranscript }

        let separator = baseText.last?.isWhitespace == true ? "" : " "
        return baseText + separator + trimmedTranscript
    }
}

struct VoiceInputTranscriptState {
    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    var text: String {
        finalizedText + volatileText
    }

    mutating func reset() {
        finalizedText = ""
        volatileText = ""
    }

    @discardableResult
    mutating func receive(_ resultText: String, isFinal: Bool) -> String {
        if isFinal {
            finalizedText += resultText
            volatileText = ""
        } else {
            volatileText = resultText
        }
        return text
    }
}

/// Publishes the first volatile result immediately, then accepts only results
/// that extend the visible prefix. Live text never rewrites itself; the final
/// accurate transcript replaces it after recording ends.
struct VoiceInputStableTranscriptState {
    private(set) var text = ""

    mutating func reset() {
        text = ""
    }

    @discardableResult
    mutating func receive(_ candidate: String) -> String {
        guard !candidate.isEmpty else { return text }
        guard text.isEmpty || candidate.hasPrefix(text) else { return text }
        text = candidate
        return candidate
    }
}
