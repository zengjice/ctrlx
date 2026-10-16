import Foundation
import Observation

/// App-owned lifecycle. UI/native Agent adapters provide presentation and launch
/// work; this owner serializes checkpoints and protects the recovery source.
@MainActor @Observable
final class WorkspaceRecoveryController {
    enum Phase: Equatable {
        case starting
        case ready
        case restoring
        case needsRecovery
        case failed
        case stopped
    }

    private(set) var phase = Phase.starting
    private(set) var snapshot: WorkspaceRecoverySnapshot?
    private(set) var liveState: WorkspaceTmuxState?
    private(set) var failures: [WorkspaceRecoveryFailure] = []
    private(set) var error: String?
    var isReady: Bool {
        phase != .starting && phase != .restoring
    }

    @ObservationIgnored private let store: WorkspaceRecoveryStore
    @ObservationIgnored private let tmux: WorkspaceTmuxClient
    @ObservationIgnored private let system: WorkspaceRecoverySystem
    @ObservationIgnored private let mode: () -> WorkspaceRecoveryMode
    @ObservationIgnored private let captureExtras: (WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot
    @ObservationIgnored private let captureViewer: (WorkspaceRecoverySnapshot) -> WorkspaceRecoverySnapshot
    @ObservationIgnored private let present: (WorkspaceRecoverySnapshot, WorkspaceTmuxState) async throws -> Void
    @ObservationIgnored private let resumeAgents: WorkspaceAgentRecoveryHandler
    @ObservationIgnored private var bootID: String?
    @ObservationIgnored private var operationInProgress = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private var closedPaneIDs: Set<String> = []
    @ObservationIgnored private var closedPaneIdentities: Set<UUID> = []
    @ObservationIgnored private var closedWindowIdentities: Set<UUID> = []
    @ObservationIgnored private var closedSessionIdentities: Set<UUID> = []

    init(
        store: WorkspaceRecoveryStore,
        tmux: WorkspaceTmuxClient,
        system: WorkspaceRecoverySystem,
        mode: @escaping () -> WorkspaceRecoveryMode,
        captureExtras: @escaping (WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot,
        present: @escaping (WorkspaceRecoverySnapshot, WorkspaceTmuxState) async throws -> Void,
        resumeAgents: @escaping WorkspaceAgentRecoveryHandler,
        captureViewer: @escaping (WorkspaceRecoverySnapshot) -> WorkspaceRecoverySnapshot = { $0 }
    ) {
        self.store = store
        self.tmux = tmux
        self.system = system
        self.mode = mode
        self.captureExtras = captureExtras
        self.captureViewer = captureViewer
        self.present = present
        self.resumeAgents = resumeAgents
    }

    func start(periodic: Bool = true) async {
        guard phase == .starting, !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            let boot = try system.bootID()
            bootID = boot
            snapshot = try await store.load()
            let live = try await tmux.capture()
            liveState = live
            switch WorkspaceRecoveryPolicy.startup(snapshot: snapshot, live: live, bootID: boot, mode: mode()) {
            case .disabled:
                phase = .ready
            case .observe:
                if let snapshot {
                    try await present(snapshot, live)
                }
                phase = .ready
                try await save(live)
            case .restore:
                try await recover()
            case .offerRestore:
                if let snapshot {
                    try await present(snapshot, live)
                }
                phase = .needsRecovery
            }
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
        if periodic, !stopping {
            periodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await self?.checkpoint()
                }
            }
        }
    }

    func checkpoint() async {
        guard
            !stopping, phase == .ready || phase == .needsRecovery || phase == .failed,
            mode() != .disabled, !operationInProgress else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        await checkpointWhileLocked()
    }

    private func checkpointWhileLocked() async {
        if phase == .failed || (phase == .needsRecovery && snapshot?.recovery == nil) {
            do { try await saveViewerState() }
            catch { self.error = error.localizedDescription }
            return
        }
        do {
            let live = try await tmux.capture()
            let recordedClosures = closedPaneIDs
            let previousPanes = Set(liveState?.sessions.flatMap(\.windows).flatMap(\.panes).map(\.runtimeID) ?? [])
            let explicitlyClosedLastPane = live.serverID == nil && !previousPanes.isEmpty && previousPanes.isSubset(of: recordedClosures)
            // Do not turn a disappearing server (including shutdown) into an
            // empty checkpoint. The last complete source remains recoverable.
            if let previous = liveState, previous.serverID != nil, previous.serverID != live.serverID, !explicitlyClosedLastPane {
                phase = .needsRecovery
                try await saveViewerState()
                return
            }
            liveState = live
            try await save(live)
            try await reconcileAgents(live)
            closedPaneIDs.subtract(recordedClosures)
            error = nil
        } catch {
            self.error = error.localizedDescription
            do { try await saveViewerState() }
            catch { self.error = "\(self.error ?? "Workspace capture failed"). \(error.localizedDescription)" }
        }
    }

    /// The actual tmux mutation participates in the journal transaction. Waiting
    /// until after kill-* to notify this owner lets an old read recreate the slot.
    func performClose(_ operation: WorkspaceRecoveryCloseOperation) async throws {
        while operationInProgress, !stopping {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        operationInProgress = true
        defer { operationInProgress = false }
        let target = try await operation()
        guard mode() != .disabled else { return }
        if let target {
            recordClosedTarget(target)
            if let snapshot {
                // A subsequent tmux read can fail. Preserve this explicit close
                // in the known snapshot, including the shutdown fallback.
                self.snapshot = applyingClosures(to: snapshot)
            }
        }
        await checkpointWhileLocked()
    }

    private func recordClosedTarget(_ target: WorkspaceRecoveryClosedTarget) {
        let sessions = liveState?.sessions ?? []
        switch target {
        case let .session(id):
            closedSessionIdentities.insert(id)
            if let session = sessions.first(where: { $0.id == id }) {
                closedPaneIDs.formUnion(session.windows.flatMap(\.panes).map(\.runtimeID))
            }
        case let .window(id):
            closedWindowIdentities.insert(id)
            if let window = sessions.flatMap(\.windows).first(where: { $0.id == id }) {
                closedPaneIDs.formUnion(window.panes.map(\.runtimeID))
            }
        case let .pane(id):
            closedPaneIdentities.insert(id)
            if let pane = sessions.flatMap(\.windows).flatMap(\.panes).first(where: { $0.id == id }) {
                closedPaneIDs.insert(pane.runtimeID)
            }
        }
    }

    func retry() async {
        await retry(intent: .automatic)
    }

    func resumeAgent(_ id: UUID) async {
        await retry(intent: .resume(id))
    }

    func useShell(_ id: UUID) async {
        await retry(intent: .useShell(id))
    }

    func failure(for paneID: String) -> WorkspaceRecoveryFailure? {
        guard let pane = liveState?.sessions.flatMap(\.windows).flatMap(\.panes).first(where: { $0.runtimeID == paneID }) else { return nil }
        return failures.first { $0.id == pane.id }
    }

    private func retry(intent: WorkspaceAgentRecoveryIntent) async {
        // A periodic checkpoint must not consume an explicit user action.
        while operationInProgress, !stopping {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { return }
        }
        guard !stopping, phase != .stopped, mode() != .disabled else { return }
        operationInProgress = true
        defer { operationInProgress = false }
        do {
            // A failed initial read must be retried, never replaced by a new snapshot.
            if snapshot == nil {
                snapshot = try await store.load()
            }
            if bootID == nil {
                bootID = try system.bootID()
            }
            if snapshot == nil {
                let live = try await tmux.capture()
                liveState = live
                phase = .ready
                try await save(live)
            } else {
                try await recover(intent: intent)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    /// Called before windows/Agent services are torn down. Uses the last complete
    /// tmux read so a server already exiting during shutdown cannot erase it.
    func stop() async {
        stopping = true
        periodicTask?.cancel()
        await periodicTask?.value
        periodicTask = nil
        while operationInProgress {
            do { try await Task.sleep(for: .milliseconds(10)) }
            catch { phase = .stopped
                return
            }
        }
        operationInProgress = true
        defer {
            operationInProgress = false
            phase = .stopped
        }
        guard mode() != .disabled, let snapshot else { return }
        do {
            if phase == .failed || (phase == .needsRecovery && snapshot.recovery == nil) {
                try await saveViewerState()
            } else {
                self.snapshot = try await store.save(withViewerState(captureExtras(snapshot)))
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Viewer presentation can change while local recovery waits for tmux.
    /// Preserve the complete local source, including its drafts and recovery intent.
    private func saveViewerState() async throws {
        guard let snapshot else { return }
        self.snapshot = try await store.save(withViewerState(snapshot))
    }

    private func withViewerState(_ source: WorkspaceRecoverySnapshot) -> WorkspaceRecoverySnapshot {
        var next = source
        let viewer = captureViewer(next)
        next.viewerScenes = viewer.viewerScenes
        next.drafts = (next.drafts.filter { $0.hostID == nil } + viewer.drafts.filter { $0.hostID != nil })
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return next
    }

    private func recover(intent: WorkspaceAgentRecoveryIntent = .automatic) async throws {
        guard var source = snapshot, let bootID else { return }
        phase = .restoring
        if source.recovery == nil {
            source.recovery = WorkspaceRecoveryAttempt(
                bootID: bootID,
                pendingAgentPaneIDs: Set(source.sessions.flatMap(\.windows).flatMap(\.panes).filter { $0.agent != nil || $0.unavailableAgentReason != nil }.map(\.id))
            )
        }
        // Persist intent first. An interrupted creation must restart from this
        // exact source, never a half-populated discovery result.
        snapshot = try await store.save(source)
        guard !stopping else { throw CancellationError() }
        let result = try await tmux.restore(source.sessions)
        liveState = result.state
        guard !stopping else { throw CancellationError() }
        let shells = source.sessions.flatMap(\.windows).flatMap(\.panes)
            .filter { $0.agent == nil && $0.unavailableAgentReason == nil }.map(\.id)
        let pendingShells = result.state.placeholderPaneIDs.intersection(shells)
            .intersection(result.createdPaneIDs.union(result.state.deadPaneIDs))
        source.recovery?.pendingAgentPaneIDs.formUnion(pendingShells)
        try await present(source, result.state)
        let (updated, agentFailures) = try await resumeAgents(source, result, intent, recordProgress)
        source = updated
        failures = result.failures + agentFailures
        if failures.isEmpty, source.recovery?.pendingAgentPaneIDs.isEmpty != false {
            source.recovery = nil
            source.bootID = bootID
            source.serverID = result.state.serverID
            snapshot = source
            phase = .ready
            try await save(result.state)
        } else {
            snapshot = try await store.save(source)
            phase = .needsRecovery
        }
    }

    private func recordProgress(_ proposed: WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot {
        guard !stopping else { throw CancellationError() }
        let saved = try await store.save(proposed)
        snapshot = saved
        return saved
    }

    private func reconcileAgents(_ live: WorkspaceTmuxState) async throws {
        guard let source = snapshot, let pending = source.recovery?.pendingAgentPaneIDs else { return }
        var updated = source
        if !pending.isEmpty {
            let result = WorkspaceTmuxRestoreResult(state: live, failures: [], createdPaneIDs: [])
            let (reconciled, agentFailures) = try await resumeAgents(source, result, .reconcile, recordProgress)
            updated = reconciled
            failures.removeAll { pending.contains($0.id) }
            failures += agentFailures
        }
        let structuresPresent = updated.sessions.allSatisfy { saved in
            guard let session = live.sessions.first(where: { $0.id == saved.id }) else { return false }
            return saved.windows.allSatisfy { window in
                guard let current = session.windows.first(where: { $0.id == window.id && $0.index == window.index }) else { return false }
                return Set(window.panes.map(\.id)).isSubset(of: Set(current.panes.map(\.id)))
            }
        }
        if
            failures.isEmpty, updated.recovery?.pendingAgentPaneIDs.isEmpty == true,
            structuresPresent, live.incompleteSessionIDs.isEmpty, live.incompleteWindowIDs.isEmpty {
            updated.recovery = nil
            phase = .ready
        }
        snapshot = try await store.save(updated)
    }

    private func save(_ live: WorkspaceTmuxState) async throws {
        guard mode() != .disabled, let bootID else { return }
        var next = applyingClosures(to: snapshot ?? WorkspaceRecoverySnapshot(hostID: UUID(), bootID: bootID, serverID: live.serverID))
        let recordedClosures = closedPaneIdentities
        let recordedSessions = closedSessionIdentities
        let recordedWindows = closedWindowIdentities
        next.bootID = bootID
        next.serverID = live.serverID
        let priorPanes = Dictionary(next.sessions.flatMap(\.windows).flatMap(\.panes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        next.sessions = next.recovery == nil ? live.sessions : Self.mergingPartial(source: next.sessions, live: live)
        for session in next.sessions.indices {
            for window in next.sessions[session].windows.indices {
                for pane in next.sessions[session].windows[window].panes.indices {
                    let id = next.sessions[session].windows[window].panes[pane].id
                    next.sessions[session].windows[window].panes[pane].agent = priorPanes[id]?.agent
                    next.sessions[session].windows[window].panes[pane].unavailableAgentReason = priorPanes[id]?.unavailableAgentReason
                    if next.recovery?.pendingAgentPaneIDs.contains(id) == true, live.placeholderPaneIDs.contains(id), let directory = priorPanes[id]?.directory {
                        next.sessions[session].windows[window].panes[pane].directory = directory
                    }
                }
            }
        }
        next = try await withViewerState(captureExtras(next))
        snapshot = try await store.save(next)
        closedPaneIdentities.subtract(recordedClosures)
        closedWindowIdentities.subtract(recordedWindows)
        closedSessionIdentities.subtract(recordedSessions)
    }

    private func applyingClosures(to source: WorkspaceRecoverySnapshot) -> WorkspaceRecoverySnapshot {
        var next = source
        let previousPanes = Set(next.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        let previousWindows = Set(next.sessions.flatMap(\.windows).map(\.id))
        next.sessions = next.sessions.compactMap { saved in
            guard !closedSessionIdentities.contains(saved.id) else { return nil }
            var session = saved
            session.windows.removeAll { closedWindowIdentities.contains($0.id) }
            guard !session.windows.isEmpty else { return nil }
            if !session.windows.contains(where: { $0.id == session.selectedWindowID }) {
                session.selectedWindowID = session.windows.first?.id
            }
            return session
        }
        next.sessions = Self.pruningClosedPanes(next.sessions, identities: closedPaneIdentities)
        let removedPanes = previousPanes.subtracting(next.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
        let removedWindows = previousWindows.subtracting(next.sessions.flatMap(\.windows).map(\.id))
        next.recovery?.pendingAgentPaneIDs.subtract(removedPanes)
        if var attempt = next.recovery {
            attempt.agentLaunches = attempt.agentLaunches.filter { !removedPanes.contains($0.key) }
            next.recovery = attempt
        }
        failures.removeAll { closedSessionIdentities.contains($0.id) || removedWindows.contains($0.id) || removedPanes.contains($0.id) }
        return next
    }

    static func pruningClosedPanes(_ source: [WorkspaceRecoverySession], identities: Set<UUID>) -> [WorkspaceRecoverySession] {
        guard !identities.isEmpty else { return source }
        return source.compactMap { saved in
            var session = saved
            session.windows = saved.windows.compactMap { savedWindow in
                guard let layout = savedWindow.layout.removing(identities) else { return nil }
                var window = savedWindow
                window.layout = layout
                window.panes.removeAll { identities.contains($0.id) }
                if window.selectedPaneID.map(identities.contains) == true {
                    window.selectedPaneID = layout.paneIDs.first
                }
                return window
            }
            guard !session.windows.isEmpty else { return nil }
            if !session.windows.contains(where: { $0.id == session.selectedWindowID }) {
                session.selectedWindowID = session.windows.first?.id
            }
            return session
        }
    }

    /// Completed windows may be edited while another window waits for a missing
    /// disk/history. Keep only the unresolved source structures, not stale copies
    /// of everything that already recovered successfully.
    static func mergingPartial(source: [WorkspaceRecoverySession], live: WorkspaceTmuxState) -> [WorkspaceRecoverySession] {
        var merged = source.map { saved in
            guard var current = live.sessions.first(where: { $0.id == saved.id }) else { return saved }
            guard live.incompleteSessionIDs.contains(saved.id) else { return current }
            let knownIDs = Set(saved.windows.map(\.id))
            let added = current.windows.filter { !knownIDs.contains($0.id) }
            current.windows = saved.windows.map { window in
                guard !live.incompleteWindowIDs.contains(window.id), let restored = current.windows.first(where: { $0.id == window.id }) else { return window }
                return restored
            } + added
            if !current.windows.contains(where: { $0.id == current.selectedWindowID }) {
                current.selectedWindowID = saved.selectedWindowID
            }
            return current
        }
        let known = Set(source.map(\.id))
        merged += live.sessions.filter { !known.contains($0.id) }
        // A missing session can still refer to a window which is live through
        // another link. Preserve that live content in every saved link while
        // keeping each session's index; incomplete windows retain one source.
        var shared = Dictionary(source.flatMap(\.windows).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for window in live.sessions.flatMap(\.windows) where !live.incompleteWindowIDs.contains(window.id) {
            shared[window.id] = window
        }
        for session in merged.indices {
            merged[session].windows = merged[session].windows.map { window in
                var resolved = shared[window.id] ?? window
                resolved.index = window.index
                return resolved
            }
        }
        return merged
    }
}
