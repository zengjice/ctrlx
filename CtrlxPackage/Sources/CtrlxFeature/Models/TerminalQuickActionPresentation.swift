import CtrlxCommon
import CtrlxNetworking
import Foundation

/// Browsing quick actions is an overlay, not a terminal focus transition.
/// Only editors need to borrow the keyboard from the terminal.
struct TerminalQuickActionPresentation: Equatable {
    enum Panel: Equatable {
        case commands(AgentCommandContext)
        case models(TerminalAgentModelPresentation)
        /// No agent identity yet. Capture only the terminal target, never guess
        /// a command catalog from a window title or previously focused pane.
        case commandsUnavailable(TerminalPhraseContext)
        case phrases(TerminalPhraseContext)
        case addCustomButton(TerminalPhraseContext)
    }

    private(set) var panel: Panel?
    var isEditingPhrase = false

    var isPresented: Bool {
        panel != nil
    }

    var suspendsTerminalInput: Bool {
        if case .addCustomButton = panel {
            return true
        }
        if case .phrases = panel {
            return isEditingPhrase
        }
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
        case (.commands?, .commands),
             (.commandsUnavailable?, .commands),
             (.commands?, .commandsUnavailable),
             (.commandsUnavailable?, .commandsUnavailable),
             (.models?, .models),
             (.phrases?, .phrases),
             (.addCustomButton?, .addCustomButton):
            dismiss()
        default:
            show(panel)
        }
    }

    mutating func toggleCommands(context: AgentCommandContext?, terminal: TerminalPhraseContext) {
        toggle(context.map(Panel.commands) ?? .commandsUnavailable(terminal))
    }

    mutating func dismiss() {
        panel = nil
        isEditingPhrase = false
    }

    mutating func validate(phraseContext: TerminalPhraseContext, commandContext: AgentCommandContext?, modelPane: WorkspacePaneIdentity? = nil, modelPluginID: String? = nil) {
        switch panel {
        case let .models(captured) where !captured.matches(context: phraseContext, pane: modelPane, pluginID: modelPluginID):
            dismiss()
        case let .commands(captured) where !captured.hasSameInput(as: commandContext):
            dismiss()
        case let .phrases(captured) where !captured.hasSameInput(as: phraseContext):
            dismiss()
        case let .addCustomButton(captured) where !captured.hasSameInput(as: phraseContext):
            dismiss()
        case let .commandsUnavailable(captured):
            guard captured.hasSameInput(as: phraseContext) else {
                dismiss()
                return
            }
            // Metadata may arrive after the user opens the explanation. Only
            // promote a catalog for that exact terminal and unchanged input.
            if
                let commandContext,
                commandContext.target.hostID == captured.target.hostID,
                commandContext.target.paneID == captured.target.paneID,
                commandContext.inputRevision == captured.inputRevision {
                show(.commands(commandContext))
            }
        default:
            break
        }
    }
}

/// Keeps asynchronous model reads and changes scoped to one opening of the panel.
struct TerminalAgentModelPresentation: Equatable, Sendable, Identifiable {
    let id = UUID()
    let context: TerminalPhraseContext
    let pluginID: String
    let pane: WorkspacePaneIdentity

    func matches(context: TerminalPhraseContext, pane: WorkspacePaneIdentity?, pluginID: String?) -> Bool {
        self.context.hasSameInput(as: context) && self.pane == pane && self.pluginID == pluginID
    }
}
