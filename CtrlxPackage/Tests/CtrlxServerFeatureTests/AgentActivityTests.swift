import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite("Persisted Agent task activity")
struct AgentActivityTests {
    @Test("Task events survive Host restarts; session start, viewing and metadata do not advance them")
    func restart() {
        let preferences = PreferencesService.inMemory()
        let identity = identity()
        let pane = pane("%1", session: "work", identity: identity)
        let manager = manager(preferences)
        manager.updatePaneStates(from: [pane])
        apply(.idle, to: "%1", at: 100, using: manager)
        #expect(manager.lastActivity(for: "%1") == nil)
        apply(.working, to: "%1", at: 200, using: manager)
        #expect(manager.lastActivity(for: "%1") == Date(timeIntervalSince1970: 200))
        apply(.doneWorking(summary: nil), to: "%1", at: 300.9, using: manager)
        manager.markSessionHandled(paneId: "%1")
        #expect(manager.lastActivity(for: "%1") == Date(timeIntervalSince1970: 300))
        #expect(!manager.updatePaneStates(from: [pane]))

        let relaunched = self.manager(preferences)
        relaunched.updatePaneStates(from: [pane])
        apply(.idle, to: "%1", at: 900, using: relaunched)
        #expect(relaunched.lastActivity(for: "%1") == Date(timeIntervalSince1970: 300))
        apply(.working, to: "%1", at: 1_000, using: relaunched)
        #expect(relaunched.lastActivity(for: "%1") == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Events arriving before metadata persist when the durable identity arrives")
    func eventBeforeMetadata() {
        let preferences = PreferencesService.inMemory()
        let manager = manager(preferences)
        apply(.doneWorking(summary: nil), to: "%1", at: 200, using: manager)
        let pane = pane("%1", session: "work", identity: identity())
        manager.updatePaneStates(from: [pane])
        let relaunched = self.manager(preferences)
        relaunched.updatePaneStates(from: [pane])
        #expect(relaunched.lastActivity(for: "%1") == Date(timeIntervalSince1970: 200))
    }

    @Test("Durable pane identity follows moves and recovery, but reused tmux numbers inherit nothing")
    func identityIsolation() {
        let preferences = PreferencesService.inMemory()
        let manager = manager(preferences)
        var identity = identity()
        manager.updatePaneStates(from: [pane("%1", session: "old", identity: identity)])
        apply(.working, to: "%1", at: 200, using: manager)

        identity.sessionID = UUID()
        identity.windowID = UUID()
        manager.updatePaneStates(from: [pane("%1", session: "renamed", identity: identity)])
        #expect(manager.lastActivity(for: "%1") == Date(timeIntervalSince1970: 200))

        identity.serverID = "new-server"
        let relaunched = self.manager(preferences)
        relaunched.updatePaneStates(from: [pane("%5", session: "restored", identity: identity)])
        #expect(relaunched.lastActivity(for: "%5") == Date(timeIntervalSince1970: 200))
        identity.paneID = UUID()
        relaunched.updatePaneStates(from: [pane("%5", session: "replacement", identity: identity)])
        #expect(relaunched.lastActivity(for: "%5") == nil)
    }

    @Test("Restarted Host and Viewers keep the same recent-task order across all tabs")
    func sharedOrderAfterRestart() throws {
        let preferences = PreferencesService.inMemory()
        let panes = [
            pane("%1", session: "cm", identity: identity()),
            pane("%2", session: "credit-hl", identity: identity()),
            pane("%3", session: "reel", identity: identity()),
            pane("%4", session: "cm", window: 1, identity: identity()),
        ]
        let manager = manager(preferences)
        manager.updatePaneStates(from: panes)
        for (id, time) in [("%1", 100.0), ("%2", 200.0), ("%3", 50.0), ("%4", 300.0)] {
            apply(.doneWorking(summary: nil), to: id, at: time, using: manager)
        }

        let relaunched = self.manager(preferences)
        relaunched.updatePaneStates(from: panes)
        for pane in panes {
            apply(.idle, to: pane.paneId, at: 1_000, using: relaunched)
        }
        let local = SessionSortData.sortedLocalSessions(
            LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes(panes)),
            mode: .statusPriority, paneStates: relaunched.paneStates,
            lastActivity: { relaunched.lastActivity(for: $0) },
            sidebarFields: SidebarField.defaultFields, sidebarTerminalFields: SidebarField.defaultTerminalFields
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = SessionStateMessage(pairId: "host", paneStates: relaunched.paneStates)
        let remoteStore = SessionStore()
        try remoteStore.handleStateUpdate(decoder.decode(SessionStateMessage.self, from: encoder.encode(snapshot)))
        let remote = SessionSortData.sortedRemoteSessions(
            remoteStore.sessions(for: "host"), sidebarFields: SidebarField.defaultFields,
            sidebarTerminalFields: SidebarField.defaultTerminalFields, homeDirectory: nil
        )
        #expect(local.map(\.sessionName) == ["cm", "credit-hl", "reel"])
        #expect(remote.map(\.sessionName) == local.map(\.sessionName))
    }

    private func apply(_ state: AgentState, to paneID: String, at seconds: TimeInterval, using manager: MirrorWindowManager) {
        manager.applyState(
            pluginID: "codex", sessionID: "session-\(paneID)", state: state,
            tmuxPane: paneID, projectPath: nil, receivedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func identity() -> WorkspacePaneIdentity {
        .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
    }

    private func pane(_ id: String, session: String, window: Int = 0, identity: WorkspacePaneIdentity) -> PaneInfo {
        PaneInfo(
            paneId: id, target: "\(session):\(window).0", sessionName: session,
            windowIndex: window, paneIndex: 0, command: "codex", currentPath: "/tmp",
            width: 80, height: 24, isActive: true, workspaceIdentity: identity
        )
    }

    private func manager(_ preferences: PreferencesService) -> MirrorWindowManager {
        withDependencies {
            $0[PreferencesService.self] = preferences
            $0[ProcessRunner.self] = .previewValue
            $0[LoginItemService.self] = .previewValue
        } operation: {
            let tmux = TmuxService()
            return MirrorWindowManager(
                settings: AppSettings(), tmuxService: tmux,
                paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                editorSessionManager: EditorSessionManager()
            )
        }
    }
}
