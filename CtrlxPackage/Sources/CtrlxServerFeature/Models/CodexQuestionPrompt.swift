import Foundation

/// A deliberately narrow recognizer for Codex's collapsed question footer.
/// Read the live screen, never scrollback or raw output chunks. Unknown layouts
/// are left alone; Shift+Left remains available manually.
struct CodexQuestionPrompt: Equatable, Sendable {
    let count: Int

    init?(lines: [String], cursorRow: Int, cursorColumn: Int) {
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
           // Codex 0.158 renders the chord without spaces. Accept both known
           // layouts, but keep other shortcuts and partial hints fail-closed.
           ["shift + ← to answer", "shift+← to answer"].contains(tail[2]) {
            let words = tail[1].split(separator: " ")
            guard words.count == 3, words[0] == "?",
                  let count = Int(words[1]), (1...999).contains(count),
                  words[2] == (count == 1 ? "question" : "questions")
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
struct CodexQuestionExpansionState {
    private(set) var count = 0

    mutating func observe(_ newCount: Int) -> Bool {
        defer { count = newCount }
        return newCount > count
    }
}
