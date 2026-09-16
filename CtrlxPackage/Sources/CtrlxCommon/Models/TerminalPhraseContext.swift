import CtrlxNetworking

/// Unlike slash commands, phrase input does not require a recognized agent.
package struct TerminalPhraseContext: Identifiable, Equatable, Sendable {
    package struct Target: Hashable, Sendable {
        package let hostID: String
        package let paneID: String?
    }

    package let target: Target
    package let inputRevision: UInt64
    package let unavailableReason: String?

    package var id: Target { target }
    package var canSend: Bool { unavailableReason == nil }

    package init(hostID: String, paneID: String?, inputRevision: UInt64,
         isConnected: Bool, isInputAvailable: Bool, hasExternalEditor: Bool = false,
         hasBlockingForm: Bool = false) {
        target = Target(hostID: hostID, paneID: paneID)
        self.inputRevision = inputRevision
        if paneID == nil {
            unavailableReason = "Select a terminal pane to send phrases."
        } else if !isConnected {
            unavailableReason = "Reconnect to the host to send phrases."
        } else if !isInputAvailable {
            unavailableReason = "Wait until the terminal is ready."
        } else if hasExternalEditor {
            unavailableReason = "Close the external editor before sending a phrase."
        } else if hasBlockingForm {
            unavailableReason = "Answer the agent's pending question or approval first."
        } else {
            unavailableReason = nil
        }
    }

    package func hasSameInput(as current: Self) -> Bool {
        target == current.target && inputRevision == current.inputRevision
    }
}

package struct TerminalPhraseRequest: Sendable {
    package let phrase: QuickPhrase
    package let context: TerminalPhraseContext

    package init(phrase: QuickPhrase, context: TerminalPhraseContext) {
        self.phrase = phrase
        self.context = context
    }

    package func isValid(in current: TerminalPhraseContext, savedPhrases: [QuickPhrase]) -> Bool {
        context.canSend && current.canSend && context.hasSameInput(as: current)
            && savedPhrases.contains(phrase)
    }
}
