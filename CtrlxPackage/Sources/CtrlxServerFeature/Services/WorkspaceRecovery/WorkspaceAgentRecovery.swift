import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

enum WorkspaceAgentRecoveryIntent: Equatable {
    case automatic
    case resume(UUID)
    case useShell(UUID)
    case reconcile
}

typealias WorkspaceRecoveryProgress = @MainActor (WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot
typealias WorkspaceAgentRecoveryHandler = @MainActor (WorkspaceRecoverySnapshot, WorkspaceTmuxRestoreResult, WorkspaceAgentRecoveryIntent, WorkspaceRecoveryProgress) async throws -> (WorkspaceRecoverySnapshot, [WorkspaceRecoveryFailure])

struct WorkspaceRecoveryAgentPane {
    var identity: UUID
    var isDead: Bool
    var isPlaceholder: Bool
    var launchID: UUID?
    var source: AgentForkSource?
}

/// Serial, journaled native resume. A dead, owned placeholder is the only launch
/// destination; uncertain results are observed before any later explicit retry.
@MainActor
final class WorkspaceAgentRecovery {
    let core: (String) -> (any AgentSessionResuming)?
    let mode: () -> WorkspaceRecoveryMode
    let refresh: () async -> Void
    let version: (String) async -> String?
    let directoryExists: (String) -> Bool
    let inspect: (String) async throws -> WorkspaceRecoveryAgentPane
    let launch: (String, WorkspaceRecoveryPane, WorkspaceRecoveryAgentLaunch, AgentForkLaunch?) async throws -> Void

    init(
        core: @escaping (String) -> (any AgentSessionResuming)?, mode: @escaping () -> WorkspaceRecoveryMode,
        refresh: @escaping () async -> Void, version: @escaping (String) async -> String?,
        directoryExists: @escaping (String) -> Bool,
        inspect: @escaping (String) async throws -> WorkspaceRecoveryAgentPane,
        launch: @escaping (String, WorkspaceRecoveryPane, WorkspaceRecoveryAgentLaunch, AgentForkLaunch?) async throws -> Void
    ) {
        self.core = core
        self.mode = mode
        self.refresh = refresh
        self.version = version
        self.directoryExists = directoryExists
        self.inspect = inspect
        self.launch = launch
    }

    func recover(
        _ source: WorkspaceRecoverySnapshot,
        result: WorkspaceTmuxRestoreResult,
        intent: WorkspaceAgentRecoveryIntent,
        save: WorkspaceRecoveryProgress
    ) async throws -> (WorkspaceRecoverySnapshot, [WorkspaceRecoveryFailure]) {
        var snapshot = source
        var failures: [WorkspaceRecoveryFailure] = []
        guard let attempt = snapshot.recovery, let serverID = result.state.serverID else { return (snapshot, []) }
        await refresh()
        let current = Dictionary(result.state.sessions.flatMap(\.windows).flatMap(\.panes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (session, window, pane) in Self.orderedTargets(in: source) where attempt.pendingAgentPaneIDs.contains(pane.id) {
            let name = "\(session.name) / \(window.name)"
            guard let live = current[pane.id] else { continue } // The tmux result already reports the unavailable structure.
            var canResume = false
            var canUseShell = false
            var keepCurrentTerminal = false
            var blocksInput = false
            var canRetry = false
            let isShell = pane.agent == nil && pane.unavailableAgentReason == nil
            do {
                let state = try await inspect(live.runtimeID)
                guard state.identity == pane.id else { throw WorkspaceRecoveryError("The recovery pane identity changed.") }
                let record = snapshot.recovery?.agentLaunches[pane.id]
                let matchingLaunch = record?.serverID == serverID && record?.runtimePaneID == live.runtimeID && record?.id == state.launchID
                if !state.isDead {
                    canUseShell = true
                    keepCurrentTerminal = true
                    if intent == .useShell(pane.id) {
                        // Explicitly keep whatever is now running. Never replace it.
                        clearAgent(pane.id, in: &snapshot)
                        snapshot = try await save(snapshot)
                        continue
                    }
                    if
                        let agent = pane.agent, let running = state.source,
                        running.pluginID == agent.pluginID && running.sessionID == agent.sessionID {
                        snapshot.recovery?.pendingAgentPaneIDs.remove(pane.id)
                        snapshot = try await save(snapshot)
                        continue
                    }
                    if matchingLaunch, record?.kind == .shell {
                        clearAgent(pane.id, in: &snapshot)
                        snapshot = try await save(snapshot)
                        continue
                    }
                    throw WorkspaceRecoveryError(matchingLaunch ? "Agent is starting; waiting to verify the original conversation." : "This pane already has a live process. It has been kept.")
                }
                guard state.isPlaceholder else { throw WorkspaceRecoveryError("This terminal is not an owned recovery placeholder.") }
                blocksInput = true
                canResume = pane.agent != nil
                canUseShell = !isShell
                canRetry = isShell
                guard directoryExists(pane.directory) else {
                    throw WorkspaceRecoveryError("The original working directory is unavailable: \(pane.directory)")
                }
                if intent == .useShell(pane.id) || (isShell && intent == .automatic) {
                    let next = WorkspaceRecoveryAgentLaunch(serverID: serverID, runtimePaneID: live.runtimeID, kind: .shell)
                    snapshot.recovery?.agentLaunches[pane.id] = next
                    snapshot = try await save(snapshot)
                    try await launch(live.runtimeID, pane, next, nil)
                    clearAgent(pane.id, in: &snapshot)
                    snapshot = try await save(snapshot)
                    continue
                }
                if isShell {
                    throw WorkspaceRecoveryError("The original terminal is saved. Choose Retry to reopen it.")
                }
                guard let descriptor = pane.agent else { throw WorkspaceRecoveryError(pane.unavailableAgentReason ?? "The original Agent conversation could not be verified.") }
                guard let agent = core(descriptor.pluginID) else { throw WorkspaceRecoveryError("The Agent plugin is disabled or unavailable. Enable it before resuming.") }
                let manual = intent == .resume(pane.id)
                guard manual || (intent == .automatic && mode() == .layoutAndAgents) else {
                    throw WorkspaceRecoveryError("Conversation is saved. Choose Resume to reopen it.")
                }
                if !manual {
                    if let reason = descriptor.automaticResumeUnavailableReason {
                        throw WorkspaceRecoveryError(reason)
                    }
                    guard
                        let executable = descriptor.executable, let recordedVersion = descriptor.cliVersion,
                        await version(executable) == recordedVersion else {
                        throw WorkspaceRecoveryError("The Agent CLI changed or is unavailable. Choose Resume to reopen it explicitly.")
                    }
                    guard !matchingLaunch else { throw WorkspaceRecoveryError("The previous resume ended. Choose Resume to retry it explicitly.") }
                }
                let command = try await agent.commandForResume(descriptor)
                let next = WorkspaceRecoveryAgentLaunch(serverID: serverID, runtimePaneID: live.runtimeID, kind: .resume)
                snapshot.recovery?.agentLaunches[pane.id] = next
                snapshot = try await save(snapshot)
                try Task.checkCancellation()
                try await launch(live.runtimeID, pane, next, command)
                // Do not claim success from command acceptance. Reconciliation
                // observes the native conversation before clearing this item.
                failures.append(.init(id: pane.id, name: name, reason: "Agent is starting; waiting to verify the original conversation."))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(.init(id: pane.id, name: name, reason: error.localizedDescription, canResume: canResume, canUseShell: canUseShell, keepCurrentTerminal: keepCurrentTerminal, blocksInput: blocksInput, canRetry: canRetry))
            }
        }
        return (snapshot, failures)
    }

    static func orderedTargets(in source: WorkspaceRecoverySnapshot) -> [(WorkspaceRecoverySession, WorkspaceRecoveryWindow, WorkspaceRecoveryPane)] {
        var visibleWindows: [UUID: Int] = [:]
        var selectedSessions: Set<UUID> = []
        for scene in source.scenes where scene.selectedHostID == nil {
            guard let presentation = scene.sessions.first(where: { $0.hostID == nil && $0.sessionID == scene.selectedSessionID }) else { continue }
            selectedSessions.insert(presentation.sessionID)
            let layout = presentation.layout
            let left = layout.selectedLeft.flatMap { layout.rightSide.contains($0) ? nil : $0 }
            let right = layout.selectedRight.flatMap { layout.rightSide.contains($0) ? $0 : nil }
            let visible = presentation.focusedRight
                ? [right, left]
                : [left, right]
            for ref in visible {
                guard
                    case let .window(index) = ref, let id = presentation.windowIDs[index],
                    presentation.ownedWindowIDs.contains(id), visibleWindows[id] == nil else { continue }
                visibleWindows[id] = visibleWindows.count
            }
        }
        let targets = source.sessions.flatMap { session in
            session.windows.flatMap { window in window.panes.map { (session, window, $0) } }
        }
        func rank(_ target: (WorkspaceRecoverySession, WorkspaceRecoveryWindow, WorkspaceRecoveryPane), index: Int) -> (Int, Int, Int, Int) {
            let (session, window, pane) = target
            if let order = visibleWindows[window.id] {
                return (0, order, pane.id == window.selectedPaneID ? 0 : 1, index)
            }
            return (selectedSessions.contains(session.id) ? 1 : 2, 0, 0, index)
        }
        var seen: Set<UUID> = []
        return targets.enumerated().sorted { rank($0.element, index: $0.offset) < rank($1.element, index: $1.offset) }
            .map(\.element).filter { seen.insert($0.2.id).inserted }
    }

    private func clearAgent(_ id: UUID, in snapshot: inout WorkspaceRecoverySnapshot) {
        snapshot.recovery?.pendingAgentPaneIDs.remove(id)
        for session in snapshot.sessions.indices {
            for window in snapshot.sessions[session].windows.indices {
                for pane in snapshot.sessions[session].windows[window].panes.indices where snapshot.sessions[session].windows[window].panes[pane].id == id {
                    snapshot.sessions[session].windows[window].panes[pane].agent = nil
                    snapshot.sessions[session].windows[window].panes[pane].unavailableAgentReason = nil
                }
            }
        }
    }
}
