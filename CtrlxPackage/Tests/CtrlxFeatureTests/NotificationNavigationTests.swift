import CtrlxCommon
import CtrlxNetworking
import Testing
@testable import CtrlxFeature

@Suite("iOS notification navigation")
struct NotificationNavigationTests {
    @Test("The notified tab wins over the first, active and saved tab", arguments: [0, 1, 2])
    func targetTab(index: Int) throws {
        let paneID = "%\(index + 1)"
        let route = try #require(SessionNavigation.notification(
            paneID: paneID, hostID: "office",
            paneStates: [PaneKey(pairId: "office", paneId: paneID): .init(paneId: paneID, sessionName: "work")]
        ))
        let candidates = (0..<3).map {
            WindowSelectionCandidate(windowId: "work:\($0)", paneId: "%\($0 + 1)", isActive: $0 == 0)
        }
        #expect(route.sessionName == "work" && route.hostId == "office")
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "work:0", candidates: candidates,
            requestedPaneId: route.paneSelection?.paneID, createdPaneId: "%1", selectedPaneId: "%1"
        ) == .select(windowId: "work:\(index)", paneId: paneID))
    }

    @Test("A notification targets a non-active split pane in its owning tab")
    func splitPane() {
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "work:0",
            candidates: [.init(windowId: "work:0", paneId: "%1", isActive: true, paneIDs: ["%1", "%9"])],
            requestedPaneId: "%9", selectedPaneId: "%1"
        ) == .select(windowId: "work:0", paneId: "%9"))
    }

    @Test("Identical pane IDs on other Hosts cannot redirect a notification")
    func hostIdentity() throws {
        let states: [PaneKey: PaneState] = [
            .init(pairId: "office", paneId: "%1"): .init(paneId: "%1", sessionName: "office-session"),
            .init(pairId: "home", paneId: "%1"): .init(paneId: "%1", sessionName: "home-session"),
        ]
        let office = try #require(SessionNavigation.notification(paneID: "%1", hostID: "office", paneStates: states))
        let home = try #require(SessionNavigation.notification(paneID: "%1", hostID: "home", paneStates: states))
        #expect(office.sessionName == "office-session" && office.hostId == "office")
        #expect(home.sessionName == "home-session" && home.hostId == "home")
        #expect(SessionNavigation.notification(paneID: "%1", hostID: "missing", paneStates: states) == nil)
    }

    @Test("Repeated taps recreate the destination so manual tab changes cannot suppress selection")
    func repeatedNotification() throws {
        let states: [PaneKey: PaneState] = [.init(pairId: "office", paneId: "%2"): .init(paneId: "%2", sessionName: "work")]
        let first = try #require(SessionNavigation.notification(paneID: "%2", hostID: "office", paneStates: states))
        let next = try #require(SessionNavigation.notification(paneID: "%2", hostID: "office", paneStates: states))
        #expect(first.paneSelection?.paneID == next.paneSelection?.paneID)
        #expect(Set([first, next]).count == 2)
    }

    @Test("A late snapshot never substitutes the first tab, and selection is not pinned after opening")
    func lateSnapshot() throws {
        let key = PaneKey(pairId: "office", paneId: "%2")
        #expect(SessionNavigation.notification(paneID: "%2", hostID: "office", paneStates: [:]) == nil)
        #expect(SessionNavigation.notification(paneID: "%2", hostID: "office", paneStates: [key: .init(paneId: "%2")]) == nil)
        let route = try #require(SessionNavigation.notification(
            paneID: "%2", hostID: "office", paneStates: [key: .init(paneId: "%2", sessionName: "work")]
        ))
        let first = WindowSelectionCandidate(windowId: "work:0", paneId: "%1", isActive: true)
        let target = WindowSelectionCandidate(windowId: "work:1", paneId: "%2", isActive: false)
        var selection = InitialPaneSelection(paneID: route.paneSelection?.paneID)
        for candidates in [[], [first]] {
            #expect(selection.resolve(candidates: candidates) == .unchanged)
            #expect(selection.isPending)
        }
        #expect(selection.resolve(candidates: [first, target]) == .select(windowId: "work:1", paneId: "%2"))
        #expect(!selection.isPending)
        #expect(selection.resolve(candidates: [first, target]) == .unchanged)
        #expect(WindowSelectionReconciliation.resolve(
            selectedWindowId: "work:0", candidates: [first, target], selectedPaneId: "%1"
        ) == .unchanged)
    }

    @Test("Manual selection recovers from a vanished target and a late snapshot cannot steal it back")
    func manuallySelectAfterTargetDisappears() {
        let first = WindowSelectionCandidate(windowId: "work:0", paneId: "%1", isActive: true)
        let vanished = WindowSelectionCandidate(windowId: "work:1", paneId: "%2", isActive: false)
        let chosen = WindowSelectionCandidate(windowId: "work:2", paneId: "%3", isActive: false)
        var selection = InitialPaneSelection(paneID: "%2")
        #expect(selection.resolve(candidates: [first, chosen]) == .unchanged)
        #expect(selection.isPending)

        selection.cancel()
        #expect(!selection.isPending)
        for candidates in [[first, chosen], [first, vanished, chosen]] {
            #expect(selection.resolve(candidates: candidates) == .unchanged)
            #expect(WindowSelectionReconciliation.resolve(
                selectedWindowId: chosen.windowId, candidates: candidates,
                requestedPaneId: selection.paneID, selectedPaneId: chosen.paneId
            ) == .unchanged)
        }
    }
}
