/// Keeps the keyboard state from the first preview in a chain of preview links.
struct ArtifactPreviewKeyboardRestore {
    private var snapshot: Snapshot?

    mutating func captureIfNeeded(paneID: String, keyboardIsActive: Bool) {
        guard snapshot == nil else { return }
        snapshot = Snapshot(paneID: paneID, keyboardWasActive: keyboardIsActive)
    }

    mutating func consume(terminalIsVisible: Bool, activePaneID: String?) -> Bool? {
        defer { snapshot = nil }
        guard terminalIsVisible, let snapshot, activePaneID == snapshot.paneID else { return nil }
        return snapshot.keyboardWasActive
    }

    mutating func discard() {
        snapshot = nil
    }

    private struct Snapshot {
        let paneID: String
        let keyboardWasActive: Bool
    }
}
