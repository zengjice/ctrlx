import Foundation

/// A deliberately narrow recognizer for Codex's collapsed question footer.
/// Read the live screen, never scrollback or raw output chunks. Unknown layouts
/// are left alone; Shift+Left remains available manually.
public struct CodexQuestionPrompt: Equatable, Sendable {
    // Presentation-only timer ticks must not restart the stability check or
    // re-arm a queue the user dismissed with Escape.
    public let count: Int

    public init?(lines: [String], cursorRow: Int, cursorColumn: Int) {
        guard lines.indices.contains(cursorRow), cursorColumn == 2 else { return nil }
        let rawComposer = lines[cursorRow]
        // Codex can animate braille particles over its empty placeholder. Do
        // not strip braille from actual user input (no known placeholder).
        let composer = (rawComposer.contains("Ask Codex to do anything")
            ? Self.withoutParticles(rawComposer) : rawComposer).trimmingCharacters(in: .whitespaces)
        // Only a known empty composer is safe. In particular, don't select a
        // character in a draft, even when its cursor happens to be at column 2.
        guard composer == "›" || composer == "› Ask Codex to do anything" else { return nil }

        let footer = lines.prefix(cursorRow).suffix(8)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !Self.withoutParticles($0).trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = Array(footer.suffix(3))
        if tail.count == 3,
           ["• Queued follow-up inputs", "Queued follow-up inputs"].contains(tail[0]),
           // Codex also omits spaces (0.158) or the plus sign (0.160).
           // Other shortcuts and partial hints remain fail-closed.
           ["shift + ← to answer", "shift+← to answer", "shift← to answer"].contains(tail[2]) {
            let words = tail[1].split(separator: " ")
            guard words.count >= 3, words[0] == "?",
                  let count = Int(words[1]), (1...999).contains(count),
                  words[2] == (count == 1 ? "question" : "questions"),
                  Self.isElapsedSuffix(words.dropFirst(3))
            else { return nil }
            self.count = count
        } else {
            // Don't treat a partial/unknown footer as an empty queue. Otherwise
            // a repaint could re-arm the same questions after Escape.
            guard composer == "› Ask Codex to do anything", !footer.contains(where: {
                $0.contains("Queued follow-up") || $0.contains("to answer") || $0.hasPrefix("?")
            }) else { return nil }
            self.count = 0
        }
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
            guard rank < previousRank, !digits.isEmpty,
                  digits.allSatisfy({ (48...57).contains($0) })
            else { return false }
            previousRank = rank
        }
        return true
    }

    private static func withoutParticles(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (0x2800...0x28ff).contains($0.value) ? UnicodeScalar(32)! : $0
        }))
    }
}

/// Once per observed queue growth. A dismissed queue must not reopen on every
/// redraw; reductions update the baseline without opening the next question.
/// With no request IDs in the TUI, equal-size replacements deliberately fail
/// closed instead of guessing whether a question is new.
public struct CodexQuestionExpansionState: Sendable {
    public private(set) var count = 0

    public init() {}

    public mutating func observe(_ newCount: Int) -> Bool {
        defer { count = newCount }
        return newCount > count
    }
}
