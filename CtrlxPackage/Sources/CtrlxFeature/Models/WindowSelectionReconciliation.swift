struct WindowSelectionCandidate: Equatable, Hashable, Sendable {
    let windowId: String
    let paneId: String?
    let isActive: Bool
    var paneIDs: [String] = []
    var stableWindowId: String?
}

struct InitialPaneSelection: Equatable, Sendable {
    private(set) var paneID: String?
    var isPending: Bool {
        paneID != nil
    }

    mutating func cancel() {
        paneID = nil
    }

    mutating func resolve(candidates: [WindowSelectionCandidate]) -> WindowSelectionReconciliation {
        guard let paneID else { return .unchanged }
        let selection = WindowSelectionReconciliation.resolve(
            selectedWindowId: nil, candidates: candidates, requestedPaneId: paneID
        )
        if case .select = selection {
            cancel()
        }
        return selection
    }
}

enum WindowSelectionReconciliation: Equatable, Sendable {
    case unchanged
    case select(windowId: String, paneId: String?)

    static func adjacentWindowID(
        from windowID: String,
        direction: TerminalWindowSwipePolicy.Direction,
        in candidates: [WindowSelectionCandidate]
    ) -> String? {
        guard let index = candidates.firstIndex(where: { $0.windowId == windowID }) else { return nil }
        let targetIndex = index + (direction == .next ? 1 : -1)
        guard candidates.indices.contains(targetIndex) else { return nil }
        return candidates[targetIndex].windowId
    }

    static func resolve(
        selectedWindowId: String?,
        candidates: [WindowSelectionCandidate],
        requestedPaneId: String? = nil,
        createdPaneId: String? = nil,
        selectedPaneId: String? = nil,
        previousCandidates: [WindowSelectionCandidate] = []
    ) -> Self {
        if let requestedPaneId {
            guard let candidate = candidates.first(where: { $0.paneId == requestedPaneId || $0.paneIDs.contains(requestedPaneId) }) else { return .unchanged }
            return .select(windowId: candidate.windowId, paneId: requestedPaneId)
        }
        if
            let createdPaneId,
            let candidate = candidates.first(where: { $0.paneId == createdPaneId || $0.paneIDs.contains(createdPaneId) }) {
            return .select(windowId: candidate.windowId, paneId: createdPaneId)
        }
        if let selectedPaneId {
            if let candidate = candidates.first(where: { $0.paneId == selectedPaneId || $0.paneIDs.contains(selectedPaneId) }) {
                return candidate.windowId == selectedWindowId
                    ? .unchanged
                    : .select(windowId: candidate.windowId, paneId: selectedPaneId)
            }
            // A closed split pane stays in its surviving window. A closed window
            // goes to the first tab, even when tmux reuses its old index.
            let previousWindow = previousCandidates.first { $0.paneId == selectedPaneId || $0.paneIDs.contains(selectedPaneId) }
            let survivingWindow = previousWindow?.stableWindowId.flatMap { stableID in
                candidates.first { $0.stableWindowId == stableID }
            }
            guard let candidate = survivingWindow ?? candidates.first else { return .unchanged }
            return .select(windowId: candidate.windowId, paneId: candidate.paneId)
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

        guard let candidate = candidates.first else { return .unchanged }
        return .select(windowId: candidate.windowId, paneId: candidate.paneId)
    }

    private static func preferredCandidate(
        in candidates: [WindowSelectionCandidate]
    ) -> WindowSelectionCandidate? {
        candidates.first(where: \.isActive) ?? candidates.first
    }
}
