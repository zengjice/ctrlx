import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceRemoteRecoveryTests {
    @MainActor
    final private class Fixture {
        let store: WorkspaceRecoveryStore
        var live: WorkspaceTmuxState
        let pane: PaneState
        var failure: WorkspaceRecoveryFailure
        var resumes = 0
        var shells = 0
        var actionFails = false
        var beforeCapture: (() async -> Void)?

        lazy var recovery = WorkspaceRecoveryController(
            store: store,
            tmux: .init(capture: {
                await self.capture()
            }, restore: { _ in
                await self.unexpectedRestore()
            }),
            system: .init(bootID: { "boot-a" }, directoryExists: { _ in true }, pathExists: { _ in true }),
            mode: { .layoutOnly }, captureExtras: { $0 }, present: { _, _ in },
            resumeAgents: { source, _, intent, _ in
                var next = source
                if intent == .resume(self.failure.id) {
                    self.resumes += 1
                    if !self.actionFails {
                        next.recovery?.agentLaunches[self.failure.id] = .init(serverID: "server-a", runtimePaneID: self.pane.paneId, kind: .resume)
                        self.failure = .init(id: self.failure.id, name: self.failure.name, reason: "Agent is starting.")
                    }
                } else if intent == .useShell(self.failure.id) {
                    self.shells += 1
                    if !self.actionFails {
                        next.recovery?.pendingAgentPaneIDs.remove(self.failure.id)
                        next.sessions[0].windows[0].panes[0].unavailableAgentReason = nil
                        return (next, [])
                    }
                }
                return (next, [self.failure])
            }
        )

        init() {
            var source = WorkspaceRecoveryStoreTests.snapshot()
            let session = source.sessions[0]
            let window = session.windows[0]
            let saved = window.panes[0]
            source.sessions[0].windows[0].panes[0].unavailableAgentReason = "Saved conversation requires manual resume."
            source.recovery = .init(bootID: source.bootID, pendingAgentPaneIDs: [saved.id])
            self.store = .inMemory(source)
            self.live = .init(serverID: source.serverID, sessions: source.sessions, placeholderPaneIDs: [saved.id], deadPaneIDs: [saved.id])
            self.pane = .init(paneId: saved.runtimeID, sessionName: session.name, workspaceIdentity: .init(serverID: "server-a", sessionID: session.id, windowID: window.id, paneID: saved.id))
            self.failure = .init(id: saved.id, name: "project / review", reason: "Conversation is saved.", canResume: true, canUseShell: true, blocksInput: true)
        }

        func capture() async -> WorkspaceTmuxState {
            await beforeCapture?()
            return live
        }

        func unexpectedRestore() -> WorkspaceTmuxRestoreResult {
            Issue.record("A remote pane action must not restore unrelated structure in this fixture")
            return .init(state: live, failures: [], createdPaneIDs: [])
        }

        func request(_ action: RecoverWorkspacePane.Action) throws -> RecoverWorkspacePane {
            try .init(paneID: pane.paneId, recovery: #require(recovery.recoveryState(for: pane)), action: action)
        }
    }

    @Test("Viewer Resume and Use Shell use the Host recovery transaction", arguments: [RecoverWorkspacePane.Action.resume, .useShell])
    func recover(action: RecoverWorkspacePane.Action) async throws {
        let fixture = Fixture()
        let recovery = fixture.recovery
        await recovery.start(periodic: false)
        let request = try fixture.request(action)
        try await recovery.recoverPane(request, expectedPane: fixture.pane.workspaceIdentity)
        #expect(fixture.resumes == (action == .resume ? 1 : 0))
        #expect(fixture.shells == (action == .useShell ? 1 : 0))
        #expect(recovery.recoveryState(for: fixture.pane)?.blocksInput != true)
        await #expect(throws: WorkspaceRecoveryError.self) {
            try await recovery.recoverPane(request, expectedPane: fixture.pane.workspaceIdentity)
        }
    }

    @Test("Missing identity, a replaced pane, a new tmux server and a closed target cannot receive recovery", arguments: ["missing", "pane", "server", "closed", "attempt", "launch"])
    func staleTarget(change: String) async throws {
        let fixture = Fixture()
        await fixture.recovery.start(periodic: false)
        var identity = fixture.pane.workspaceIdentity
        var request = try fixture.request(.resume)
        switch change {
        case "missing": identity = nil
        case "pane": fixture.live.sessions[0].windows[0].panes[0].id = UUID()
        case "server": fixture.live.serverID = "new-server"
        case "closed": fixture.live.sessions = []
        default:
            let state = try #require(fixture.recovery.recoveryState(for: fixture.pane))
            request = .init(paneID: fixture.pane.paneId, recovery: .init(
                attemptID: change == "attempt" ? UUID() : state.attemptID,
                launchID: change == "launch" ? UUID() : state.launchID,
                name: state.name, reason: state.reason, canResume: true, canUseShell: true,
                keepCurrentTerminal: false, canRetry: false, blocksInput: true, isReady: true
            ), action: .resume)
        }
        await #expect(throws: WorkspaceRecoveryError.self) {
            try await fixture.recovery.recoverPane(request, expectedPane: identity)
        }
        #expect(fixture.resumes == 0 && fixture.shells == 0)
    }

    @Test("Queued requests are revalidated after a preceding action completes")
    func queuedDuplicate() async throws {
        let fixture = Fixture()
        await fixture.recovery.start(periodic: false)
        let request = try fixture.request(.resume)
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        fixture.beforeCapture = {
            fixture.beforeCapture = nil
            entered.continuation.yield(())
            for await _ in released.stream {
                break
            }
        }
        let first = Task { try await fixture.recovery.recoverPane(request, expectedPane: fixture.pane.workspaceIdentity) }
        for await _ in entered.stream {
            break
        }
        let queued = AsyncStream<Void>.makeStream()
        let second = Task {
            queued.continuation.yield(())
            await #expect(throws: WorkspaceRecoveryError.self) {
                try await fixture.recovery.recoverPane(request, expectedPane: fixture.pane.workspaceIdentity)
            }
        }
        for await _ in queued.stream {
            break
        }
        released.continuation.yield(())
        try await first.value
        await second.value
        #expect(fixture.resumes == 1)
    }

    @Test("Recovery changes push once; unchanged checkpoints do not republish, and unrelated panes have no actions")
    func publication() async throws {
        let fixture = Fixture()
        var publications = 0
        fixture.recovery.onStateChange = { publications += 1 }
        await fixture.recovery.start(periodic: false)
        #expect(publications == 1)
        await fixture.recovery.checkpoint()
        #expect(publications == 1)
        var replaced = fixture.pane
        replaced.workspaceIdentity?.paneID = UUID()
        #expect(fixture.recovery.recoveryState(for: replaced) == nil)
        try await fixture.recovery.recoverPane(fixture.request(.useShell), expectedPane: fixture.pane.workspaceIdentity)
        #expect(publications > 1)
        #expect(fixture.recovery.recoveryState(for: fixture.pane) == nil)
    }

    @Test("Host failures remain recoverable and are returned to the Viewer")
    func failedAction() async throws {
        let fixture = Fixture()
        await fixture.recovery.start(periodic: false)
        fixture.actionFails = true
        await #expect(throws: WorkspaceRecoveryError(fixture.failure.reason)) {
            try await fixture.recovery.recoverPane(fixture.request(.resume), expectedPane: fixture.pane.workspaceIdentity)
        }
        #expect(fixture.recovery.phase == .needsRecovery)
        #expect(fixture.recovery.recoveryState(for: fixture.pane)?.canResume == true)
    }
}
