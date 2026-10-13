import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Remote automatic session sorting")
struct RemoteAutomaticSessionSortTests {
    @Test("iOS automatic ordering prioritizes working sessions despite a legacy Host mode")
    func activityFirstWithLegacyHost() {
        let store = SessionStore()
        update(store, ux: .idle, cm: .working)
        #expect(store.sidebarSortMode(for: "host") == .statusPriorityIdleFirst)
        #expect(orderedNames(store) == ["cm", "ios", "ux", "window"])

        update(store, ux: .doneWorking(summary: nil), cm: .working)
        #expect(orderedNames(store) == ["ux", "cm", "ios", "window"])

        update(store, ux: .idle, cm: .idle)
        #expect(orderedNames(store) == ["cm", "ios", "ux", "window"])
    }

    @Test("Clearing a manual order restores the current activity order")
    func restoresAfterManualOrder() {
        let store = SessionStore()
        update(store, ux: .idle, cm: .working)
        let manualOrder = ["ux", "cm", "window", "ios"]
        #expect(orderedNames(store, manualOrder: manualOrder) == manualOrder)

        #expect(orderedNames(store, manualOrder: []) == ["cm", "ios", "ux", "window"])

        update(store, ux: .working, cm: .idle)
        #expect(orderedNames(store, manualOrder: []) == ["ux", "cm", "ios", "window"])
    }

    @Test("Explicit Mac sort modes still take precedence over the shared default")
    func preservesExplicitSortMode() {
        let store = SessionStore()
        update(store, ux: .idle, cm: .working)
        let sessions = SessionSortData.sortedRemoteSessions(
            store.sessions(for: "host"),
            mode: .statusPriorityIdleFirst,
            sidebarFields: SidebarField.defaultFields,
            sidebarTerminalFields: SidebarField.defaultTerminalFields,
            homeDirectory: nil
        )
        #expect(sessions.map(\.sessionName) == ["ios", "ux", "cm", "window"])
    }

    private func update(_ store: SessionStore, ux: AgentState, cm: AgentState) {
        let panes = [
            PaneState(paneId: "%1", sessionName: "ux", agentSession: AgentSession(paneId: "%1", state: ux)),
            PaneState(paneId: "%2", sessionName: "cm", agentSession: AgentSession(paneId: "%2", state: cm)),
            PaneState(paneId: "%3", sessionName: "ios", agentSession: AgentSession(paneId: "%3", state: .idle)),
            PaneState(paneId: "%4", sessionName: "window"),
        ]
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host",
            paneStates: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) }),
            sidebarSortMode: SidebarSortMode.statusPriorityIdleFirst.rawValue
        ))
    }

    private func orderedNames(_ store: SessionStore, manualOrder: [String] = []) -> [String] {
        SessionSortData.sortedRemoteSessions(
            store.sessions(for: "host"),
            sidebarFields: SidebarField.defaultFields,
            sidebarTerminalFields: SidebarField.defaultTerminalFields,
            homeDirectory: nil,
            preferredSessionNames: manualOrder
        ).map(\.sessionName)
    }
}
