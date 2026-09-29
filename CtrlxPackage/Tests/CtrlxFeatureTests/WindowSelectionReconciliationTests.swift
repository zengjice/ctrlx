import Testing
@testable import CtrlxFeature

@Suite("Window selection reconciliation")
struct WindowSelectionReconciliationTests {
    @Test("New window selection follows its pane even when the state arrives late")
    func createdWindow() {
        let original = candidate("@1", paneId: "%1", isActive: true)
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "@1", candidates: [original], createdPaneId: "%2"
        ) == .unchanged)
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "@1", candidates: [original, candidate("@2", paneId: "%2")], createdPaneId: "%2"
        ) == .select(windowId: "@2", paneId: "%2"))
    }

    @Test("Creation selection can find a non-active pane; a manual choice stays selected once pending creation clears")
    func createdPaneMembership() {
        let candidates = [
            candidate("@1", paneId: "%1"),
            WindowSelectionCandidate(windowId: "@2", paneId: "%3", isActive: true, paneIDs: ["%2", "%3"]),
        ]
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "@1", candidates: candidates, createdPaneId: "%2"
        ) == .select(windowId: "@2", paneId: "%2"))
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "@1", candidates: candidates, createdPaneId: nil
        ) == .unchanged)
    }

    @Test("Keeps an existing selection")
    func existingSelection() {
        let candidates = [
            candidate("@1", paneId: "%1"),
            candidate("@2", paneId: "%2", isActive: true),
        ]

        #expect(
            WindowSelectionReconciliation.resolve(
                selectedWindowId: "@1",
                candidates: candidates
            ) == .unchanged
        )
    }

    @Test("Initial selection prefers the active window")
    func initialSelection() {
        let candidates = [
            candidate("@1", paneId: "%1"),
            candidate("@2", paneId: "%2", isActive: true),
        ]

        #expect(
            WindowSelectionReconciliation.resolve(
                selectedWindowId: nil,
                candidates: candidates
            ) == .select(windowId: "@2", paneId: "%2")
        )
    }

    @Test("Missing selection falls back to the active window")
    func missingSelection() {
        let candidates = [
            candidate("@1", paneId: "%1"),
            candidate("@2", paneId: "%2", isActive: true),
        ]

        #expect(
            WindowSelectionReconciliation.resolve(
                selectedWindowId: "@missing",
                candidates: candidates
            ) == .select(windowId: "@2", paneId: "%2")
        )
    }

    @Test("Missing selection falls back to the first window when none is active")
    func missingSelectionWithoutActiveWindow() {
        let candidates = [
            candidate("@1", paneId: "%1"),
            candidate("@2", paneId: "%2"),
        ]

        #expect(
            WindowSelectionReconciliation.resolve(
                selectedWindowId: "@missing",
                candidates: candidates
            ) == .select(windowId: "@1", paneId: "%1")
        )
    }

    @Test("Empty initial state does not claim the session disappeared")
    func emptyInitialState() {
        #expect(
            WindowSelectionReconciliation.resolve(
                selectedWindowId: nil,
                candidates: []
            ) == .unchanged
        )
    }

    @Test("Empty state with a prior selection preserves navigation")
    func transientEmptyState() {
        #expect(
            WindowSelectionReconciliation.resolve(
                selectedWindowId: "@1",
                candidates: []
            ) == .unchanged
        )
    }

    private func candidate(
        _ windowId: String,
        paneId: String?,
        isActive: Bool = false
    ) -> WindowSelectionCandidate {
        WindowSelectionCandidate(
            windowId: windowId,
            paneId: paneId,
            isActive: isActive
        )
    }
}
