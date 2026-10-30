import Foundation

/// Captured once at recording start. Terminal output is background evidence,
/// never an authoritative copy of the remote application's input draft.
public struct VoiceInputContextSnapshot: Equatable, Encodable, Sendable {
    public let paneMetadata: [String]
    public let terminalText: String?
    public let inputDraft: String?

    public init(paneMetadata: [String] = [], terminalText: String? = nil, inputDraft: String? = nil) {
        self.paneMetadata = paneMetadata
        self.terminalText = VoiceInputContext.terminalExcerpt(terminalText)
        self.inputDraft = VoiceInputContext.terminalExcerpt(inputDraft)
    }

    /// Native editors can supply their actual draft. Terminal adapters must not
    /// populate this field from a shadow keyboard document or previous dictation.
    func formatted(maximumCount: Int = VoiceInputContext.maximumTerminalCharacterCount) -> String? {
        guard maximumCount > 0 else { return nil }
        var sections: [String] = []
        var remaining = maximumCount
        if let inputDraft {
            let header = "Existing input draft (reference only; do not reproduce):\n"
            if let excerpt = VoiceInputContext.terminalExcerpt(inputDraft, maximumCount: remaining - header.count) {
                let section = header + excerpt
                sections.append(section)
                remaining -= section.count + 2
            }
        }
        if
            let background = VoiceInputContext.makeTerminalContext(
                terminalText: terminalText, metadata: paneMetadata, maximumCount: remaining
            ) {
            sections.append(background)
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
