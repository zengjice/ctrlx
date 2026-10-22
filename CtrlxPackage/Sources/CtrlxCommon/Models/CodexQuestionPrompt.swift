import Foundation

/// A deliberately narrow recognizer for Codex's collapsed question footer.
/// Read the live screen, never scrollback or raw output chunks. Unknown layouts
/// are left alone; Shift+Left remains available manually.
public struct CodexQuestionPrompt: Equatable, Sendable {
    public enum RecognitionError: String, Error, Sendable {
        case cursorOutsideScreen = "cursor-outside-screen"
        case cursorNotAtStart = "cursor-not-at-start"
        case unrecognizedComposer = "unrecognized-composer"
        case unrecognizedFooter = "unrecognized-footer"
    }

    /// Presentation-only timer ticks must not restart the stability check or
    /// re-arm a queue the user dismissed with Escape.
    public let count: Int

    public init?(lines: [String], cursorRow: Int, cursorColumn: Int) {
        guard let prompt = try? Self(validating: lines, cursorRow: cursorRow, cursorColumn: cursorColumn) else { return nil }
        self = prompt
    }

    public init(validating lines: [String], cursorRow: Int, cursorColumn: Int) throws(RecognitionError) {
        guard lines.indices.contains(cursorRow) else { throw .cursorOutsideScreen }
        guard cursorColumn == 2 else { throw .cursorNotAtStart }
        let rawComposer = lines[cursorRow]
        // Codex can animate braille particles over its empty placeholder. Do
        // not strip braille from actual user input (no known placeholder).
        let composer = (rawComposer.contains("Ask Codex to do anything")
            ? Self.withoutParticles(rawComposer) : rawComposer).trimmingCharacters(in: .whitespaces)
        // Only a known empty composer is safe. In particular, don't select a
        // character in a draft, even when its cursor happens to be at column 2.
        guard composer == "›" || composer == "› Ask Codex to do anything" else { throw .unrecognizedComposer }

        let footer = lines.prefix(cursorRow).suffix(8)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !Self.withoutParticles($0).trimmingCharacters(in: .whitespaces).isEmpty }
        if let count = Self.questionCount(in: Array(footer)) {
            self.count = count
        } else {
            // Don't treat a partial/unknown footer as an empty queue. Otherwise
            // a repaint could re-arm the same questions after Escape.
            guard
                composer == "› Ask Codex to do anything", !footer.contains(where: {
                    $0.contains("Queued follow-up") || $0.contains("to answer") || $0.hasPrefix("?")
                }) else { throw .unrecognizedFooter }
            self.count = 0
        }
    }

    private static func questionCount(in footer: [String]) -> Int? {
        // A complete known footer must end at the composer. Joining only these
        // nearby rows tolerates wrapping without scanning history or skipping text.
        for start in footer.indices {
            var words = footer[start...].joined(separator: " ").split(whereSeparator: \.isWhitespace)
            if words.first == "•" {
                words.removeFirst()
            }
            guard
                words.count >= 7, words[0] == "Queued", words[1] == "follow-up", words[2] == "inputs",
                words[3] == "?", let count = Int(words[4]), (1...999).contains(count),
                words[5] == (count == 1 ? "question" : "questions")
            else { continue }
            var suffix = words.dropFirst(6)
            // Codex places its usage warning between Questions and the composer.
            // Accept only the complete known suffix, including wrapped rows.
            if let warningIndex = suffix.firstIndex(of: "⚠") {
                guard isWeeklyLimitWarning(suffix[warningIndex...]) else { continue }
                suffix = suffix[..<warningIndex]
            }
            for ageLength in 0...min(4, suffix.count) {
                if
                    isElapsedSuffix(suffix.prefix(ageLength)),
                    isAnswerHint(suffix.dropFirst(ageLength).joined(separator: " ")) {
                    return count
                }
            }
        }
        return nil
    }

    private static func isWeeklyLimitWarning(_ words: ArraySlice<Substring>) -> Bool {
        guard words.starts(with: ["⚠", "weekly", "limit:"]) else { return false }
        var suffix = words.dropFirst(3)
        if suffix.first == "only" {
            suffix = suffix.dropFirst()
        }
        guard let percentage = suffix.first, percentage.last == "%" else { return false }
        let digits = percentage.dropLast()
        guard
            !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
            let remaining = Int(digits), (0...100).contains(remaining)
        else { return false }
        let tail = suffix.dropFirst()
        return tail.elementsEqual(["left"]) || tail.elementsEqual(["left", "·", "/status"])
    }

    private static func isAnswerHint(_ text: String) -> Bool {
        let compact = text.lowercased().filter { !$0.isWhitespace }
            .replacingOccurrences(of: "⇧", with: "shift")
        return ["shift←toanswer", "shift+←toanswer", "shiftlefttoanswer", "shift+lefttoanswer"].contains(compact)
    }

    /// Optional question age, e.g. `· 14s` or `· 1m 02s`. Do not accept
    /// arbitrary text after the count: partial/unknown footers stay manual.
    private static func isElapsedSuffix(_ words: ArraySlice<Substring>) -> Bool {
        guard !words.isEmpty else { return true }
        guard (2...4).contains(words.count), words.first == "·" else { return false }
        var previousRank = 3
        for component in words.dropFirst() {
            let rank: Int
            switch component.last {
            case "h": rank = 2
            case "m": rank = 1
            case "s": rank = 0
            default: return false
            }
            let digits = component.dropLast().utf8
            guard
                rank < previousRank, !digits.isEmpty,
                digits.allSatisfy({ (48...57).contains($0) })
            else { return false }
            previousRank = rank
        }
        return true
    }

    private static func withoutParticles(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (0x2800...0x28FF).contains($0.value) ? UnicodeScalar(32)! : $0
        }))
    }
}

/// Once per observed queue growth. A dismissed queue must not reopen on every
/// redraw; reductions update the baseline without opening the next question.
/// With no request IDs in the TUI, equal-size replacements deliberately fail
/// closed instead of guessing whether a question is new.
public struct CodexQuestionExpansionState: Sendable {
    public private(set) var count = 0

    public init() { }

    public mutating func observe(_ newCount: Int) -> Bool {
        defer { count = newCount }
        return newCount > count
    }
}
