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

        update(store, ux: .idle, cm: .idle, activity: ["cm": Date(timeIntervalSince1970: 200)])
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

    @Test("Idle sessions sort by task activity, then name for ties or missing times", arguments: [
        SidebarSortMode.statusPriority, .statusPriorityIdleFirst,
    ])
    func idleTaskActivity(mode: SidebarSortMode) {
        let store = SessionStore()
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        update(store, ux: .idle, cm: .idle, activity: ["ux": newer, "cm": older])
        #expect(orderedNames(store, mode: mode) == ["ux", "cm", "ios", "window"])
        #expect(orderedNames(store, mode: .sessionName) == ["cm", "ios", "ux", "window"])

        update(store, ux: .idle, cm: .idle, activity: ["ux": newer, "cm": newer])
        #expect(orderedNames(store, mode: mode) == ["cm", "ux", "ios", "window"])

        update(store, ux: .idle, cm: .idle)
        #expect(orderedNames(store, mode: mode) == ["cm", "ios", "ux", "window"])
    }

    @Test("Task recency does not change status buckets or ordering of working sessions")
    func recencyOnlyBreaksIdleTies() {
        let store = SessionStore()
        let activity = ["ux": Date(timeIntervalSince1970: 200)]
        update(store, ux: .idle, cm: .working, activity: activity)
        #expect(orderedNames(store) == ["cm", "ux", "ios", "window"])
        #expect(orderedNames(store, mode: .statusPriorityIdleFirst) == ["ux", "ios", "cm", "window"])

        update(store, ux: .idle, cm: .doneWorking(summary: nil), activity: activity)
        #expect(orderedNames(store) == ["cm", "ux", "ios", "window"])

        update(store, ux: .working, cm: .working, activity: activity)
        #expect(orderedNames(store) == ["cm", "ux", "ios", "window"])
    }

    @Test("Viewing, status delivery and reconnecting retain Host task times")
    func preservesHostActivity() throws {
        let store = SessionStore()
        let activity = [
            "ux": Date(timeIntervalSince1970: 200),
            "cm": Date(timeIntervalSince1970: 100),
        ]
        update(store, ux: .idle, cm: .doneWorking(summary: nil), activity: activity)
        store.markSessionHandled(paneId: "%2", hostId: "host")
        #expect(orderedNames(store) == ["ux", "cm", "ios", "window"])

        store.handleAgentStatus(AgentSessionStatusMessage(
            pairId: "host", sessionId: "%2", pluginId: "codex", state: .idle,
            timestamp: Date(timeIntervalSince1970: 300)
        ))
        #expect(orderedNames(store) == ["ux", "cm", "ios", "window"])
        let cm = try #require(store.sessions(for: "host").first { $0.sessionName == "cm" })
        #expect(cm.windows.first?.panes.first?.lastAgentActivityAt == activity["cm"])

        store.clearSessions(for: "host")
        update(store, ux: .idle, cm: .idle, activity: activity)
        #expect(orderedNames(store) == ["ux", "cm", "ios", "window"])
    }

    @Test("A working second tab drives session status and order until it stops")
    func secondTabActivity() throws {
        let store = SessionStore()
        let panes = [
            PaneState(paneId: "%1", sessionName: "ux", agentSession: AgentSession(paneId: "%1", state: .idle)),
            PaneState(
                paneId: "%2", sessionName: "ux", windowIndex: 1,
                agentSession: AgentSession(paneId: "%2", state: .working)
            ),
            PaneState(paneId: "%3", sessionName: "cm", agentSession: AgentSession(paneId: "%3", state: .idle)),
        ]
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host", paneStates: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) })
        ))
        let session = try #require(store.sessions(for: "host").first { $0.sessionName == "ux" })
        #expect(session.agentPane?.paneId == "%2")
        #expect(session.agentSession?.statusLabel == "Working")
        #expect(session.displayedState == .working)
        #expect(orderedNames(store) == ["ux", "cm"])

        store.handleAgentStatus(AgentSessionStatusMessage(
            pairId: "host", sessionId: "%2", pluginId: "codex", state: .doneWorking(summary: nil), timestamp: Date()
        ))
        let finished = try #require(store.sessions(for: "host").first { $0.sessionName == "ux" })
        #expect(finished.displayedState == .waiting)
        #expect(finished.windows.flatMap(\.panes).effectiveProgress == nil)

        store.markSessionHandled(paneId: "%2", hostId: "host")
        let idle = try #require(store.sessions(for: "host").first { $0.sessionName == "ux" })
        #expect(idle.displayedState == .idle)
        #expect(idle.agentSession?.statusLabel == "Idle")
        #expect(orderedNames(store) == ["cm", "ux"])
    }

    @Test("A manual session state still overrides a working sibling pane")
    func manualStateWithMultipleAgents() {
        let panes = [
            PaneState(
                paneId: "%1", sessionName: "ux",
                agentSession: AgentSession(paneId: "%1", state: .idle), cliSessionState: .idle
            ),
            PaneState(
                paneId: "%2", sessionName: "ux", paneIndex: 1,
                agentSession: AgentSession(paneId: "%2", state: .working)
            ),
        ]
        let session = TmuxSession.groupWindows(TmuxWindow.groupPanes(panes)).first
        #expect(session?.agentPane?.paneId == "%2")
        #expect(session?.displayedState == .idle)
    }

    private func update(
        _ store: SessionStore,
        ux: AgentState,
        cm: AgentState,
        activity: [String: Date] = [:]
    ) {
        let panes = [
            PaneState(
                paneId: "%1", sessionName: "ux", agentSession: AgentSession(paneId: "%1", state: ux),
                lastAgentActivityAt: activity["ux"]
            ),
            PaneState(
                paneId: "%2", sessionName: "cm", agentSession: AgentSession(paneId: "%2", state: cm),
                lastAgentActivityAt: activity["cm"]
            ),
            PaneState(paneId: "%3", sessionName: "ios", agentSession: AgentSession(paneId: "%3", state: .idle)),
            PaneState(paneId: "%4", sessionName: "window"),
        ]
        store.handleStateUpdate(SessionStateMessage(
            pairId: "host",
            paneStates: Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0) }),
            sidebarSortMode: SidebarSortMode.statusPriorityIdleFirst.rawValue
        ))
    }

    private func orderedNames(
        _ store: SessionStore,
        mode: SidebarSortMode = .statusPriority,
        manualOrder: [String] = []
    ) -> [String] {
        SessionSortData.sortedRemoteSessions(
            store.sessions(for: "host"),
            mode: mode,
            sidebarFields: SidebarField.defaultFields,
            sidebarTerminalFields: SidebarField.defaultTerminalFields,
            homeDirectory: nil,
            preferredSessionNames: manualOrder
        ).map(\.sessionName)
    }
}
