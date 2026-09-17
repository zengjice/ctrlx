import CtrlxCommon

/// Browsing quick actions is an overlay, not a terminal focus transition.
/// Only the phrase editor needs to borrow the keyboard from the terminal.
struct TerminalQuickActionPresentation: Equatable {
    enum Panel: Equatable {
        case commands(AgentCommandContext)
        case phrases(TerminalPhraseContext)
    }

    private(set) var panel: Panel?
    var isEditingPhrase = false

    var isPresented: Bool { panel != nil }
    var suspendsTerminalInput: Bool {
        if case .phrases = panel { return isEditingPhrase }
        return false
    }

    mutating func show(_ panel: Panel) {
        self.panel = panel
        isEditingPhrase = false
    }

    /// The toolbar button controls its panel even if connection availability
    /// changed since it opened. A different button switches panels directly.
    mutating func toggle(_ panel: Panel) {
        switch (self.panel, panel) {
        case (.commands?, .commands), (.phrases?, .phrases):
            dismiss()
        default:
            show(panel)
        }
    }

    mutating func dismiss() {
        panel = nil
        isEditingPhrase = false
    }

    mutating func validate(phraseContext: TerminalPhraseContext, commandContext: AgentCommandContext?) {
        switch panel {
        case let .commands(captured) where !captured.hasSameInput(as: commandContext):
            dismiss()
        case let .phrases(captured) where !captured.hasSameInput(as: phraseContext):
            dismiss()
        default:
            break
        }
    }
}
