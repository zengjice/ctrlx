import ConcurrencyExtras
import CtrlxNetworking
import Foundation
import Observation
import Testing
@testable import CtrlxCommon

@MainActor
struct SessionGroupingCacheTests {
    @Test("Agent status without tmux metadata never creates a blank session", arguments: [false, true])
    func statusBeforeMetadata(fullSnapshot: Bool) {
        let store = SessionStore()
        let real = PaneState(
            paneId: "%1", sessionName: "experience-model",
            agentSession: .init(paneId: "%1", pluginID: "codex", state: .idle)
        )
        var pending = PaneState(
            paneId: "%99", agentSession: .init(paneId: "%99", pluginID: "codex", state: .working)
        )
        store.handleStateUpdate(.init(
            pairId: "host", paneStates: fullSnapshot ? ["%1": real, "%99": pending] : ["%1": real]
        ))
        if !fullSnapshot {
            store.handleAgentStatus(.init(
                pairId: "host", sessionId: "%99", pluginId: "codex", state: .working, timestamp: Date()
            ))
        }

        #expect(store.windows(for: "host").map(\.sessionName) == ["experience-model"])
        #expect(store.sessions(for: "host").map(\.sessionName) == ["experience-model"])
        #expect(store.session(named: "", hostId: "host") == nil)
        #expect(store.session(named: "experience-model", hostId: "host")?.agentSession?.state == .idle)
        #expect(store.paneState(for: "%99", hostId: "host")?.agentSession?.state == .working)

        pending.sessionName = "new-work"
        store.handleStateUpdate(.init(pairId: "host", paneStates: ["%1": real, "%99": pending]))
        #expect(store.sessions(for: "host").map(\.sessionName) == ["experience-model", "new-work"])
        #expect(store.session(named: "new-work", hostId: "host")?.agentSession?.state == .working)
    }

    @Test("Warm grouping stays observed and invalidates for status, handled state, replacement and disconnection")
    func hostLifetime() {
        let store = SessionStore()
        var pane = PaneState(paneId: "%1", sessionName: "work", agentSession: .init(paneId: "%1", state: .doneWorking(summary: nil)))
        for host in ["home", "office"] {
            store.handleStateUpdate(.init(pairId: host, paneStates: ["%1": pane]))
        }
        _ = store.sessions(for: "home")
        _ = store.sessions(for: "office")
        let changes = LockIsolated(0)
        withObservationTracking { _ = store.sessions(for: "home") } onChange: { changes.withValue { $0 += 1 } }
        store.markSessionHandled(paneId: "%1", hostId: "home")
        #expect(changes.value == 1)
        #expect(store.session(named: "work", hostId: "home")?.agentSession?.state == .idle)
        #expect(store.session(named: "work", hostId: "office")?.agentSession?.state == .doneWorking(summary: nil))
        pane.sessionName = "renamed"
        pane.width = 120
        pane.workspaceIdentity = .init(serverID: "new-server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        store.handleStateUpdate(.init(pairId: "home", paneStates: ["%1": pane]))
        #expect(store.session(named: "work", hostId: "home") == nil)
        #expect(store.session(named: "renamed", hostId: "home")?.windows.first?.panes.first?.width == 120)
        #expect(store.windows(for: "home").first?.panes.first?.workspaceIdentity == pane.workspaceIdentity)
        store.clearSessions(for: "home")
        #expect(store.sessions(for: "home").isEmpty)
        #expect(store.session(named: "renamed", hostId: "home") == nil)
        #expect(store.sessions(for: "office").first?.sessionName == "work")
    }

    @Test("Independent resource sessions are present in cold and warm targeted lookups")
    func resourceOnly() {
        let store = SessionStore()
        let resource = ResourceSession(id: UUID(), name: "files", directory: "/repo")
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:], independentResources: .init(sessions: [resource])))
        #expect(store.session(named: "files", hostId: "home")?.resourceSession == resource)
        #expect(store.session(named: "files", hostId: "office") == nil)
        #expect(store.sessions(for: "home").first?.resourceSession == resource)
        #expect(store.session(named: "files", hostId: "home")?.windows.isEmpty == true)
        store.handleStateUpdate(.init(pairId: "home", paneStates: [:]))
        #expect(store.session(named: "files", hostId: "home") == nil)
        #expect(store.sessions(for: "home").isEmpty)
    }

    @Test("All sort modes compute each session's keys once", arguments: SidebarSortMode.allCases)
    func sortKeysOnce(mode: SidebarSortMode) {
        let items = (0..<128).reversed().map { $0 }
        var calls: [Int: Int] = [:]
        let sorted = mode.sorted(items) { item in
            calls[item, default: 0] += 1
            return .init(sessionName: String(format: "%03d", item), primaryLabel: String(format: "%03d", item), hasClaude: false, statusPriority: 3, statusPriorityIdleFirst: 3, latestEventTimestamp: nil)
        }
        #expect(calls.count == items.count)
        #expect(calls.values.allSatisfy { $0 == 1 })
        #expect(sorted == Array(0..<128))
    }
}
