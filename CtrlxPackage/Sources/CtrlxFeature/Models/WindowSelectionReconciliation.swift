struct WindowSelectionCandidate: Equatable, Hashable, Sendable {
    let windowId: String
    let paneId: String?
    let isActive: Bool
    var paneIDs: [String] = []
}

enum WindowSelectionReconciliation: Equatable, Sendable {
    case unchanged
    case select(windowId: String, paneId: String?)

    static func resolve(
        selectedWindowId: String?,
        candidates: [WindowSelectionCandidate],
        createdPaneId: String? = nil
    ) -> Self {
        if let createdPaneId,
           let candidate = candidates.first(where: { $0.paneId == createdPaneId || $0.paneIDs.contains(createdPaneId) }) {
            return .select(windowId: candidate.windowId, paneId: createdPaneId)
        }
        guard let selectedWindowId else {
            guard let candidate = preferredCandidate(in: candidates) else {
                return .unchanged
            }
            return .select(windowId: candidate.windowId, paneId: candidate.paneId)
        }

        if candidates.contains(where: { $0.windowId == selectedWindowId }) {
            return .unchanged
        }

        guard let candidate = preferredCandidate(in: candidates) else { return .unchanged }
        return .select(windowId: candidate.windowId, paneId: candidate.paneId)
    }

    private static func preferredCandidate(
        in candidates: [WindowSelectionCandidate]
    ) -> WindowSelectionCandidate? {
        candidates.first(where: \.isActive) ?? candidates.first
    }
}
