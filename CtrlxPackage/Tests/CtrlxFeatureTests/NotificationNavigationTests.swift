import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxFeature

@Suite("iOS notification navigation")
struct NotificationNavigationTests {
    private func fixture(paneID: String = "%2", pairID: String = "office", session: String = "work", agentID: AgentID = .init(hostID: UUID(), paneID: UUID())) throws -> (AgentID, ViewerWorkspaceCatalog) {
        var pane = PaneState(paneId: paneID, sessionName: session)
        pane.tmuxWindowId = "@2"
        pane.workspaceIdentity = .init(serverID: "current", sessionID: UUID(), windowID: UUID(), paneID: agentID.paneID)
        let message = SessionStateMessage(pairId: pairID, paneStates: [paneID: pane], workspaceIdentity: .init(hostID: agentID.hostID, serverID: "current"))
        return try (agentID, #require(ViewerWorkspaceCatalog(state: message)))
    }

    @Test("The notified tab wins over the first, active and saved tab", arguments: [0, 1, 2])
    func targetTab(index: Int) throws {
        let paneID = "%\(index + 1)"
        let (agent, catalog) = try fixture(paneID: paneID)
        let route = try #require(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: catalog))
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

    @Test("Reused raw IDs and other Hosts cannot redirect a notification")
    func hostIdentity() throws {
        let (agent, office) = try fixture(paneID: "%1")
        let (_, home) = try fixture(paneID: "%1", pairID: "home")
        #expect(SessionNavigation.notification(agentID: agent, hostID: "home", catalog: home) == nil)
        #expect(SessionNavigation.notification(agentID: agent, hostID: "home", catalog: office) == nil)
        let (_, replacement) = try fixture(paneID: "%1", agentID: .init(hostID: agent.hostID, paneID: UUID()))
        #expect(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: replacement) == nil)
        #expect(SessionNavigation.notification(agentID: nil, hostID: "office", catalog: office) == nil)
        let (_, moved) = try fixture(paneID: "%42", session: "moved", agentID: agent)
        let route = try #require(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: moved))
        #expect(route.sessionName == "moved" && route.paneSelection?.paneID == "%42")
    }

    @Test("Repeated taps recreate the destination so manual tab changes cannot suppress selection")
    func repeatedNotification() throws {
        let (agent, catalog) = try fixture()
        let first = try #require(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: catalog))
        let next = try #require(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: catalog))
        #expect(first.paneSelection?.paneID == next.paneSelection?.paneID)
        #expect(Set([first, next]).count == 2)
    }

    @Test("A late snapshot never substitutes the first tab, and selection is not pinned after opening")
    func lateSnapshot() throws {
        let (agent, catalog) = try fixture()
        #expect(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: nil) == nil)
        let route = try #require(SessionNavigation.notification(agentID: agent, hostID: "office", catalog: catalog))
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
