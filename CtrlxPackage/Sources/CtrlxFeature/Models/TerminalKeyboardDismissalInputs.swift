import CtrlxCommon

/// Child-owned input presentation is authoritative, including private sheets.
struct TerminalKeyboardDismissalInputs {
    private var presentations: [String: TerminalInputPresentation.State] = [:]

    func allowsFit(paneID: String?) -> Bool {
        guard let paneID else { return false }
        return presentations[paneID]?.allowsKeyboardDismissalFit == true
    }

    mutating func update(
        _ input: TerminalInputPresentation.State?,
        paneID: String,
        activePaneID: String?,
        fit: inout TerminalTabFit
    ) {
        presentations[paneID] = input
        if paneID == activePaneID, input?.allowsKeyboardDismissalFit != true {
            fit.cancelKeyboardDismissal()
        }
    }
}
