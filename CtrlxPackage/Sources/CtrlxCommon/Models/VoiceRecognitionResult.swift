import Foundation

struct VoiceRecognitionResult: Sendable {
    let primaryTranscript: String
    let alternativeTranscripts: [String]
    let liveTranscript: String
    let diagnosticID: String

    init(
        primaryTranscript: String,
        alternativeTranscripts: [String] = [],
        liveTranscript: String = "",
        diagnosticID: String = UUID().uuidString
    ) {
        self.primaryTranscript = primaryTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alternativeTranscripts = Self.uniqueNonempty(
            alternativeTranscripts,
            excluding: self.primaryTranscript
        )
        self.liveTranscript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        self.diagnosticID = diagnosticID
    }

    var bestAvailableTranscript: String {
        primaryTranscript.isEmpty ? liveTranscript : primaryTranscript
    }

    private static func uniqueNonempty(_ values: [String], excluding excluded: String) -> [String] {
        var seen = Set([excluded])
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

/// Builds a small N-best list when Speech emits an utterance as multiple result
/// segments. Lower-ranked alternatives are pruned eagerly so correction input
/// stays bounded even for long dictation.
struct VoiceRecognitionCandidateAccumulator {
    private struct Candidate {
        let text: String
        let rank: Int
        let insertionOrder: Int
    }

    private let maximumCandidateCount: Int
    private var candidates: [Candidate] = [.init(text: "", rank: 0, insertionOrder: 0)]
    private var nextInsertionOrder = 1

    init(maximumCandidateCount: Int = 3) {
        self.maximumCandidateCount = max(1, maximumCandidateCount)
    }

    mutating func append(primary: String, alternatives: [String]) {
        let options = uniqueSegmentOptions(primary: primary, alternatives: alternatives)
        guard !options.isEmpty else { return }

        var combined: [Candidate] = []
        for prefix in candidates {
            for (optionIndex, option) in options.enumerated() {
                combined.append(
                    Candidate(
                        text: prefix.text + option,
                        rank: prefix.rank + optionIndex,
                        insertionOrder: nextInsertionOrder
                    )
                )
                nextInsertionOrder += 1
            }
        }

        combined.sort {
            if $0.rank != $1.rank {
                return $0.rank < $1.rank
            }
            return $0.insertionOrder < $1.insertionOrder
        }

        var seen = Set<String>()
        candidates = combined.filter { seen.insert($0.text).inserted }
        if candidates.count > maximumCandidateCount {
            candidates.removeLast(candidates.count - maximumCandidateCount)
        }
    }

    func makeResult(liveTranscript: String, diagnosticID: String) -> VoiceRecognitionResult {
        let transcripts = candidates
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return VoiceRecognitionResult(
            primaryTranscript: transcripts.first ?? "",
            alternativeTranscripts: Array(transcripts.dropFirst()),
            liveTranscript: liveTranscript,
            diagnosticID: diagnosticID
        )
    }

    private func uniqueSegmentOptions(primary: String, alternatives: [String]) -> [String] {
        var seen = Set<String>()
        return ([primary] + alternatives).filter { option in
            !option.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(option).inserted
        }
    }
}

public enum VoiceInputContext {
    public static let maximumTerminalCharacterCount = 12_000
    static let terminalHeader = "Recent terminal text:\n"

    public static func paneMetadata(
        sessionName: String, windowName: String, command: String?, currentPath: String?
    ) -> [String] {
        [
            ("Session", sessionName),
            ("Window", windowName),
            ("Running command", command ?? ""),
            ("Current path", currentPath ?? ""),
        ]
        .compactMap { label, value in value.isEmpty ? nil : "\(label): \(value)" }
    }

    public static func terminalExcerpt(
        _ text: String?,
        maximumCount: Int = maximumTerminalCharacterCount
    ) -> String? {
        guard maximumCount > 0 else { return nil }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumCount else { return trimmed }
        guard maximumCount > 1 else { return String(trimmed.suffix(maximumCount)) }
        return "…" + trimmed.suffix(maximumCount - 1)
    }

    /// Formats the active pane metadata and recent terminal text under one
    /// shared budget. Metadata remains intact while older terminal output is
    /// discarded first.
    public static func makeTerminalContext(
        terminalText: String?,
        metadata: [String] = [],
        maximumCount: Int = maximumTerminalCharacterCount
    ) -> String? {
        guard maximumCount > 0 else { return nil }

        let metadataText = metadata
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let terminalText = terminalText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !terminalText.isEmpty else {
            return terminalExcerpt(metadataText, maximumCount: maximumCount)
        }

        let fixedText = metadataText.isEmpty
            ? terminalHeader
            : metadataText + "\n" + terminalHeader
        guard fixedText.count < maximumCount else {
            return terminalExcerpt(metadataText, maximumCount: maximumCount)
        }

        let terminalBudget = maximumCount - fixedText.count
        guard let excerpt = terminalExcerpt(terminalText, maximumCount: terminalBudget) else {
            return terminalExcerpt(metadataText, maximumCount: maximumCount)
        }
        return fixedText + excerpt
    }
}
