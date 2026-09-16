import CtrlxNetworking

/// Unlike slash commands, phrase input does not require a recognized agent.
struct TerminalPhraseContext: Identifiable, Equatable, Sendable {
    struct Target: Hashable, Sendable {
        let hostID: String
        let paneID: String?
    }

    let target: Target
    let inputRevision: UInt64
    let unavailableReason: String?

    var id: Target { target }
    var canSend: Bool { unavailableReason == nil }

    init(hostID: String, paneID: String?, inputRevision: UInt64,
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

    func hasSameInput(as current: Self) -> Bool {
        target == current.target && inputRevision == current.inputRevision
    }
}

struct TerminalPhraseRequest: Sendable {
    let phrase: QuickPhrase
    let context: TerminalPhraseContext

    func isValid(in current: TerminalPhraseContext, savedPhrases: [QuickPhrase]) -> Bool {
        context.canSend && current.canSend && context.hasSameInput(as: current)
            && savedPhrases.contains(phrase)
    }
}
