import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceRecoveryControllerTests {
    @MainActor
    final private class Gate {
        var armed = false
        private let entered = AsyncStream<Void>.makeStream()
        private let released = AsyncStream<Void>.makeStream()

        func pause() async {
            guard armed else { return }
            armed = false
            entered.continuation.yield(())
            for await _ in released.stream {
                break
            }
        }

        func waitUntilPaused() async {
            for await _ in entered.stream {
                break
            }
        }

        func resume() {
            released.continuation.yield(())
        }
    }

    @MainActor
    final private class Backend {
        var state = WorkspaceTmuxState(serverID: nil, sessions: [])
        var restores = 0
        var captures = 0
        var failRestore = false
        var failCapture = false
        var restoreResult: WorkspaceTmuxRestoreResult?
        var beforeCaptureReturns: (() async -> Void)?
        var beforeRestoreReturns: (() async -> Void)?
        let store: WorkspaceRecoveryStore

        init(store: WorkspaceRecoveryStore) {
            self.store = store
        }

        var client: WorkspaceTmuxClient {
            WorkspaceTmuxClient(capture: { try await self.capture() }, restore: { try await self.restore($0) })
        }

        func capture() async throws -> WorkspaceTmuxState {
            captures += 1
            if failCapture {
                throw WorkspaceRecoveryError("Cannot read tmux")
            }
            let captured = state
            await beforeCaptureReturns?()
            return captured
        }

        func restore(_ sessions: [WorkspaceRecoverySession]) async throws -> WorkspaceTmuxRestoreResult {
            restores += 1
            #expect(try await store.load()?.recovery != nil, "Recovery intent must be durable before tmux creation")
            if failRestore {
                throw WorkspaceRecoveryError("tmux unavailable")
            }
            let result = restoreResult ?? .init(
                state: .init(serverID: "new-server", sessions: sessions), failures: [],
                createdPaneIDs: Set(sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
            )
            state = result.state
            await beforeRestoreReturns?()
            return result
        }
    }

    private func controller(
        _ backend: Backend, boot: String, mode: WorkspaceRecoveryMode = .layoutAndAgents,
        captureExtras: @escaping (WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot = { $0 },
        present: @escaping (WorkspaceRecoverySnapshot, WorkspaceTmuxState) async throws -> Void = { _, _ in },
        resumeAgents: @escaping WorkspaceAgentRecoveryHandler = { source, _, _, _ in (source, []) }
    ) -> WorkspaceRecoveryController {
        WorkspaceRecoveryController(
            store: backend.store, tmux: backend.client,
            system: .init(bootID: { boot }, directoryExists: { _ in true }, pathExists: { _ in true }), mode: { mode },
            captureExtras: captureExtras, present: present, resumeAgents: resumeAgents
        )
    }

    @Test("A reboot checkpoints recovery intent then completes against the new server")
    func reboot() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        let recovery = controller(backend, boot: "new-boot")
        await recovery.start(periodic: false)
        #expect(recovery.phase == .ready)
        #expect(backend.restores == 1)
        let saved = try #require(try await backend.store.load())
        #expect(saved.recovery == nil)
        #expect(saved.bootID == "new-boot" && saved.serverID == "new-server")
        #expect(saved.sessions == original.sessions)
        await recovery.stop()
    }

    @Test("Only new or stopped shell placeholders remain pending; their original directory survives capture", arguments: ["bootstrap", "stopped", "kept"])
    func pendingShellDirectory(state: String) async throws {
        var original = WorkspaceRecoveryStoreTests.snapshot()
        original.sessions[0].windows[0].panes[0].directory = "/unmounted/project"
        let pane = original.sessions[0].windows[0].panes[0]
        let backend = Backend(store: .inMemory(original))
        var live = WorkspaceTmuxState(serverID: "new-server", sessions: original.sessions, placeholderPaneIDs: [pane.id])
        live.sessions[0].windows[0].panes[0].directory = "/"
        if state == "stopped" {
            live.deadPaneIDs = [pane.id]
        }
        backend.restoreResult = .init(state: live, failures: [], createdPaneIDs: state == "bootstrap" ? [pane.id] : [])
        let recovery = controller(backend, boot: "new-boot", resumeAgents: { source, _, _, _ in
            #expect(source.recovery?.pendingAgentPaneIDs == (state == "kept" ? [] : [pane.id]))
            return (source, [.init(id: pane.id, name: "project", reason: "Fixture remains pending")])
        })
        await recovery.start(periodic: false)
        await recovery.checkpoint()
        let saved = try #require(try await backend.store.load())
        #expect(saved.sessions[0].windows[0].panes[0].directory == (state == "kept" ? "/" : pane.directory))
        await recovery.retry()
        #expect(recovery.error == nil)
        await recovery.stop()
    }

    @Test("An explicit Retry waits for an in-flight checkpoint instead of losing the click")
    func retryDuringCheckpoint() async {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.restoreResult = .init(
            state: .init(serverID: "new-server", sessions: original.sessions),
            failures: [.init(id: original.sessions[0].id, name: "project", reason: "Fixture unavailable")], createdPaneIDs: []
        )
        let recovery = controller(backend, boot: "new-boot")
        await recovery.start(periodic: false)
        #expect(recovery.phase == .needsRecovery && backend.restores == 1)
        backend.restoreResult = nil
        let gate = Gate()
        gate.armed = true
        backend.beforeCaptureReturns = { await gate.pause() }
        let checkpoint = Task { await recovery.checkpoint() }
        await gate.waitUntilPaused()
        let requested = AsyncStream<Void>.makeStream()
        let retried = Task {
            requested.continuation.yield(())
            await recovery.retry()
        }
        for await _ in requested.stream {
            break
        }
        #expect(backend.restores == 1)
        gate.resume()
        await checkpoint.value
        await retried.value
        #expect(backend.restores == 2)
        #expect(recovery.phase == .ready)
        await recovery.stop()
    }

    @Test("App restart and periodic capture never recreate a session closed in the surviving server")
    func liveServer() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        #expect(backend.restores == 0)
        backend.state.sessions = []
        await recovery.checkpoint()
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
        #expect(backend.restores == 0)
        await recovery.stop()
    }

    @Test("A disappearing tmux server preserves the last workspace, including during shutdown")
    func disappearingServer() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        backend.state = .init(serverID: nil, sessions: [])
        await recovery.checkpoint()
        #expect(recovery.phase == .needsRecovery)
        #expect(try await backend.store.load()?.sessions == original.sessions)
        let captureCount = backend.captures
        await recovery.stop()
        #expect(backend.captures == captureCount)
        #expect(try await backend.store.load()?.sessions == original.sessions)
    }

    @Test("Explicitly closing the last pane saves the empty workspace")
    func explicitLastClosure() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        backend.state = .init(serverID: nil, sessions: [])
        try await recovery.performClose { .pane(original.sessions[0].windows[0].panes[0].id) }
        #expect(recovery.phase == .ready)
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
        await recovery.stop()
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
    }

    @Test("Older capture, presentation and journal writes cannot put a closed pane back", arguments: ["capture", "extras", "write"])
    func closureDuringCapture(stage: String) async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let gate = Gate()
        let disk = WorkspaceRecoveryStore.inMemory(original)
        let store = WorkspaceRecoveryStore(load: { try await disk.load() }, save: { proposed in
            let saved = try await disk.save(proposed)
            if stage == "write" {
                await gate.pause()
            }
            return saved
        })
        let backend = Backend(store: store)
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        if stage == "capture" {
            backend.beforeCaptureReturns = { await gate.pause() }
        }
        let recovery = controller(backend, boot: original.bootID, captureExtras: { source in
            if stage == "extras" {
                await gate.pause()
            }
            return source
        })
        await recovery.start(periodic: false)
        try #require(recovery.phase == .ready)
        gate.armed = true
        let checkpoint = Task { await recovery.checkpoint() }
        await gate.waitUntilPaused()
        let requested = AsyncStream<Void>.makeStream()
        var mutated = false
        let close = Task {
            requested.continuation.yield(())
            try await recovery.performClose {
                mutated = true
                backend.state = .init(serverID: nil, sessions: [])
                return .pane(original.sessions[0].windows[0].panes[0].id)
            }
        }
        for await _ in requested.stream {
            break
        }
        #expect(!mutated, "The actual kill must wait for the old capture/write to finish")
        gate.resume()
        await checkpoint.value
        try await close.value
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
        await recovery.stop()
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
    }

    @Test("Close waits for tmux restoration, presentation and Agent progress before mutating", arguments: ["tmux", "presentation", "agent"])
    func closureDuringRecovery(stage: String) async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let gate = Gate()
        gate.armed = true
        let backend = Backend(store: .inMemory(original))
        if stage == "tmux" {
            backend.beforeRestoreReturns = { await gate.pause() }
        }
        let recovery = controller(backend, boot: "new-boot", present: { _, _ in
            if stage == "presentation" {
                await gate.pause()
            }
        }, resumeAgents: { source, _, _, save in
            if stage == "agent" {
                await gate.pause()
            }
            return try await (save(source), [])
        })
        let starting = Task { await recovery.start(periodic: false) }
        await gate.waitUntilPaused()
        let requested = AsyncStream<Void>.makeStream()
        var mutated = false
        let close = Task {
            requested.continuation.yield(())
            try await recovery.performClose {
                mutated = true
                backend.state = .init(serverID: nil, sessions: [])
                return .session(original.sessions[0].id)
            }
        }
        for await _ in requested.stream {
            break
        }
        #expect(!mutated)
        gate.resume()
        await starting.value
        try await close.value
        #expect(recovery.phase == .ready)
        #expect(backend.restores == 1)
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
        await recovery.stop()
    }

    @Test("An accepted close remains durable when the following tmux read fails", arguments: [false, true])
    func closureWithReadFailure(unknownIdentity: Bool) async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        backend.failCapture = true
        try await recovery.performClose {
            backend.state = .init(serverID: nil, sessions: [])
            return .pane(unknownIdentity ? UUID() : original.sessions[0].windows[0].panes[0].id)
        }
        #expect(recovery.error == "Cannot read tmux")
        #expect(try await backend.store.load()?.sessions == (unknownIdentity ? original.sessions : []))
        await recovery.stop()
        #expect(try await backend.store.load()?.sessions == (unknownIdentity ? original.sessions : []))
    }

    @Test("Shutdown waits for an accepted close and refuses subsequent mutations")
    func shutdownDuringClose() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        let gate = Gate()
        gate.armed = true
        let close = Task {
            try await recovery.performClose {
                backend.state = .init(serverID: nil, sessions: [])
                await gate.pause()
                return .pane(original.sessions[0].windows[0].panes[0].id)
            }
        }
        await gate.waitUntilPaused()
        let stopping = AsyncStream<Void>.makeStream()
        let stop = Task {
            stopping.continuation.yield(())
            await recovery.stop()
        }
        for await _ in stopping.stream {
            break
        }
        gate.resume()
        try await close.value
        await stop.value
        #expect(recovery.phase == .stopped)
        #expect(try await backend.store.load()?.sessions.isEmpty == true)
        var mutated = false
        await #expect(throws: CancellationError.self) {
            try await recovery.performClose { mutated = true
                return nil
            }
        }
        #expect(!mutated)
    }

    @Test("A failed close leaves the journal intact and releases the transaction")
    func failedClose() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        await #expect(throws: WorkspaceRecoveryError.self) {
            try await recovery.performClose { throw WorkspaceRecoveryError("kill failed") }
        }
        #expect(try await backend.store.load()?.sessions == original.sessions)
        backend.state.sessions[0].name = "updated"
        await recovery.checkpoint()
        #expect(try await backend.store.load()?.sessions[0].name == "updated")
        await recovery.stop()
    }

    @Test("Cancelling a queued close prevents its later tmux mutation")
    func cancelledQueuedClose() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.state = .init(serverID: original.serverID, sessions: original.sessions)
        let recovery = controller(backend, boot: original.bootID)
        await recovery.start(periodic: false)
        let gate = Gate()
        gate.armed = true
        backend.beforeCaptureReturns = { await gate.pause() }
        let checkpoint = Task { await recovery.checkpoint() }
        await gate.waitUntilPaused()
        let requested = AsyncStream<Void>.makeStream()
        var mutated = false
        let close = Task {
            requested.continuation.yield(())
            try await recovery.performClose { mutated = true
                return .session(original.sessions[0].id)
            }
        }
        for await _ in requested.stream {
            break
        }
        close.cancel()
        await #expect(throws: CancellationError.self) { try await close.value }
        gate.resume()
        await checkpoint.value
        #expect(!mutated)
        #expect(try await backend.store.load()?.sessions == original.sessions)
        await recovery.stop()
    }

    @Test("Closing a session preserves shared panes and their pending Agent recovery in the surviving link")
    func closeLinkedSession() async throws {
        var source = WorkspaceRecoveryStoreTests.snapshot()
        let pane = source.sessions[0].windows[0].panes[0]
        source.sessions[0].windows[0].panes[0].unavailableAgentReason = "Waiting for native history"
        var linked = source.sessions[0]
        linked.id = UUID()
        linked.runtimeID = "$2"
        linked.name = "linked"
        linked.windows[0].index = 7
        source.sessions.append(linked)
        let backend = Backend(store: .inMemory(source))
        let recovery = controller(backend, boot: "new-boot")
        await recovery.start(periodic: false)
        #expect(recovery.phase == .needsRecovery)
        backend.state.sessions = [linked]
        try await recovery.performClose { .session(source.sessions[0].id) }
        let saved = try #require(try await backend.store.load())
        #expect(saved.sessions == [linked])
        #expect(saved.recovery?.pendingAgentPaneIDs == [pane.id])
        #expect(saved.sessions[0].windows[0].panes[0].unavailableAgentReason == "Waiting for native history")
        await recovery.retry()
        #expect(backend.state.sessions.map(\.id) == [linked.id])
        await recovery.stop()
    }

    @Test("Closing an incomplete session or window also discards its uncreated panes", arguments: [false, true])
    func closeIncompleteTarget(session: Bool) async throws {
        var source = WorkspaceRecoveryStoreTests.snapshot()
        var first = source.sessions[0]
        let pending = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%88", directory: "/missing", unavailableAgentReason: "Directory unavailable")
        first.windows[0].panes.append(pending)
        first.windows[0].layout = .horizontal([
            .pane(first.windows[0].panes[0].id, width: 59, height: 40),
            .pane(pending.id, width: 60, height: 40),
        ], width: 120, height: 40)
        var other = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
        other.runtimeID = "$2"
        other.name = "other"
        other.windows[0].runtimeID = "@2"
        other.windows[0].panes[0].runtimeID = "%2"
        var live = source.sessions[0]
        let windowID = live.windows[0].id
        source.sessions = [first, other]
        live.windows[0].panes[0].unavailableAgentReason = nil
        let backend = Backend(store: .inMemory(source))
        backend.restoreResult = .init(
            state: .init(serverID: "new-server", sessions: [live, other], incompleteSessionIDs: [first.id], incompleteWindowIDs: [windowID]),
            failures: [.init(id: windowID, name: first.name, reason: "Directory unavailable")], createdPaneIDs: []
        )
        let recovery = controller(backend, boot: "new-boot")
        await recovery.start(periodic: false)
        #expect(recovery.phase == .needsRecovery)
        backend.state = .init(serverID: "new-server", sessions: [other])
        try await recovery.performClose { session ? .session(first.id) : .window(first.windows[0].id) }
        let saved = try #require(try await backend.store.load())
        #expect(saved.sessions == [other])
        #expect(saved.recovery == nil && recovery.failures.isEmpty && recovery.phase == .ready)
        await recovery.stop()
        let restarted = controller(backend, boot: "new-boot")
        await restarted.start(periodic: false)
        #expect(backend.restores == 1)
        #expect(try await backend.store.load()?.sessions == [other])
        await restarted.stop()
    }

    @Test("A failed restore keeps its source and resumes after App restart in the same boot")
    func interruptedRecovery() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        backend.failRestore = true
        let first = controller(backend, boot: "new-boot")
        await first.start(periodic: false)
        #expect(first.phase == .failed)
        let saved = try #require(try await backend.store.load())
        #expect(saved.recovery != nil && saved.sessions == original.sessions)
        await first.stop()
        backend.failRestore = false
        let second = controller(backend, boot: "new-boot")
        await second.start(periodic: false)
        #expect(second.phase == .ready)
        #expect(backend.restores == 2)
        #expect(try await backend.store.load()?.recovery == nil)
        await second.stop()
    }

    @Test("Failure to save recovery intent prevents tmux mutation")
    func journalFailure() async {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let store = WorkspaceRecoveryStore(load: { original }, save: { _ in throw WorkspaceRecoveryError("Disk full") })
        let backend = Backend(store: store)
        let recovery = controller(backend, boot: "new-boot")
        await recovery.start(periodic: false)
        #expect(recovery.phase == .failed)
        #expect(backend.restores == 0)
        #expect(recovery.error == "Disk full")
        await recovery.stop()
    }

    @Test("Disabled recovery preserves the existing snapshot without reconstructing it")
    func disabled() async throws {
        let original = WorkspaceRecoveryStoreTests.snapshot()
        let backend = Backend(store: .inMemory(original))
        let recovery = controller(backend, boot: "new-boot", mode: .disabled)
        await recovery.start(periodic: false)
        await recovery.checkpoint()
        await recovery.stop()
        #expect(backend.restores == 0)
        #expect(try await backend.store.load() == original)
    }

    @Test("Partial recovery preserves unresolved layouts while saving edits to completed windows")
    func partialEdits() {
        var original = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
        let first = original.windows[0]
        var second = first
        second.id = UUID()
        second.index = 1
        second.runtimeID = "@2"
        original.windows.append(second)
        var live = original
        live.windows[0].name = "edited after recovery"
        live.windows.removeLast()
        let state = WorkspaceTmuxState(serverID: "new-server", sessions: [live], incompleteSessionIDs: [original.id])
        let merged = WorkspaceRecoveryController.mergingPartial(source: [original], live: state)
        #expect(merged[0].windows[0].name == "edited after recovery")
        #expect(merged[0].windows[1] == second)
    }

    @Test("Partial checkpoints keep linked window contents consistent even while one session is missing", arguments: [false, true])
    func sharedPartialEdits(incomplete: Bool) throws {
        var source = WorkspaceRecoveryStoreTests.snapshot()
        var linked = source.sessions[0]
        linked.id = UUID()
        linked.runtimeID = "$2"
        linked.name = "linked"
        linked.windows[0].index = 7
        source.sessions.append(linked)
        var live = source.sessions[0]
        live.windows[0].runtimeID = "@99"
        live.windows[0].name = "edited after recovery"
        live.windows[0].panes[0].runtimeID = "%99"
        let state = WorkspaceTmuxState(
            serverID: "new", sessions: [live],
            incompleteSessionIDs: incomplete ? [live.id] : [],
            incompleteWindowIDs: incomplete ? [live.windows[0].id] : []
        )
        source.sessions = WorkspaceRecoveryController.mergingPartial(source: source.sessions, live: state)
        try source.validate()
        let windows = source.sessions.flatMap(\.windows)
        #expect(windows.map(\.index) == [0, 7])
        #expect(windows.allSatisfy { $0.name == (incomplete ? "terminal" : "edited after recovery") })
        #expect(windows.allSatisfy { $0.runtimeID == (incomplete ? "@1" : "@99") })
    }

    @Test("Closing a recovered pane removes only that saved slot and leaves pending siblings recoverable")
    func pruneClosedPartialPane() throws {
        var source = WorkspaceRecoveryStoreTests.snapshot()
        let original = source.sessions[0].windows[0].panes[0]
        var pending = original
        pending.id = UUID()
        pending.runtimeID = "%2"
        source.sessions[0].windows[0].panes.append(pending)
        source.sessions[0].windows[0].layout = .horizontal([
            .pane(original.id, width: 59, height: 40), .pane(pending.id, width: 60, height: 40),
        ], width: 120, height: 40)
        source.sessions = WorkspaceRecoveryController.pruningClosedPanes(source.sessions, identities: [original.id])
        try source.validate()
        let window = try #require(source.sessions.first?.windows.first)
        #expect(window.panes.map(\.id) == [pending.id])
        #expect(window.selectedPaneID == pending.id)
        #expect(window.layout == .pane(pending.id, width: 120, height: 40))
        #expect(WorkspaceRecoveryController.pruningClosedPanes(source.sessions, identities: [pending.id]).isEmpty)
    }

    @Test("Viewer checkpoints continue while local tmux is unavailable without changing the local recovery source", arguments: ["missing", "disappeared", "readFailure", "initialReadFailure"])
    func independentViewerCheckpoint(failure: String) async throws {
        var original = WorkspaceRecoveryStoreTests.snapshot()
        let localDraft = WorkspaceRecoveryDraft(id: UUID(), paneID: original.sessions[0].windows[0].panes[0].id, text: "local draft")
        original.drafts = [localDraft]
        let backend = Backend(store: .inMemory(original))
        backend.state = failure == "missing" ? .init(serverID: nil, sessions: []) : .init(serverID: original.serverID, sessions: original.sessions)
        backend.failCapture = failure == "initialReadFailure"
        var draft = WorkspaceRecoveryDraft(id: UUID(), hostID: "pair", paneID: UUID(), text: "remote draft")
        draft.remoteReference = .init(pairID: "pair", hostID: UUID(), sessionID: UUID(), windowID: UUID(), paneID: draft.paneID)
        let viewerScene = WorkspaceRecoveryScene(id: UUID(), isMain: true, sessions: [])
        let bootID = original.bootID
        let recovery = WorkspaceRecoveryController(
            store: backend.store, tmux: backend.client,
            system: .init(bootID: { bootID }, directoryExists: { _ in true }, pathExists: { _ in true }),
            mode: { .layoutAndAgents }, captureExtras: { $0 }, present: { _, _ in },
            resumeAgents: { source, _, _, _ in (source, []) }, captureViewer: { source in
                var next = source
                next.sessions = [] // The Viewer callback cannot replace local structures.
                next.drafts = [draft]
                next.viewerScenes = [viewerScene]
                return next
            }
        )
        await recovery.start(periodic: false)
        if failure == "disappeared" {
            backend.state = .init(serverID: nil, sessions: [])
        }
        if failure == "readFailure" {
            backend.failCapture = true
        }
        await recovery.checkpoint()
        let first = try #require(try await backend.store.load())
        #expect(first.sessions == original.sessions && first.bootID == original.bootID && first.serverID == original.serverID)
        #expect(first.drafts.contains(localDraft) && first.drafts.contains(draft))
        #expect(first.viewerScenes == [viewerScene])
        #expect(backend.restores == 0)
        await recovery.checkpoint()
        #expect(try await backend.store.load()?.generation == first.generation)
        draft.text = "last remote edit before quit"
        await recovery.stop()
        let final = try #require(try await backend.store.load())
        #expect(final.drafts.contains(draft) && final.drafts.contains(localDraft))
        #expect(final.sessions == original.sessions)
    }

    @Test("Viewer checkpoints cannot overwrite a snapshot that failed to load")
    func viewerCannotOverwriteUnreadSource() async {
        actor Writes {
            var saveCount = 0
            func save(_ snapshot: WorkspaceRecoverySnapshot) -> WorkspaceRecoverySnapshot {
                saveCount += 1
                return snapshot
            }
        }
        let writes = Writes()
        let store = WorkspaceRecoveryStore(load: { throw WorkspaceRecoveryError("Corrupt snapshot") }, save: { await writes.save($0) })
        let backend = Backend(store: store)
        let recovery = controller(backend, boot: "boot")
        await recovery.start(periodic: false)
        await recovery.checkpoint()
        await recovery.stop()
        #expect(await writes.saveCount == 0)
    }
}
