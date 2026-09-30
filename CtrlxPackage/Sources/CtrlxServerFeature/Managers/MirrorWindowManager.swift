import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Logging

/// Manages pane state, agent session status, and session tracking.
@Observable
@MainActor
final public class MirrorWindowManager {
    /// Unified per-pane state keyed by pane ID.
    /// Contains tmux metadata, agent session, terminal title, and yolo mode.
    public private(set) var paneStates: [String: PaneState] = [:]

    /// Canonical terminal-window arrangements published to every Viewer.
    /// Layout revisions are assigned here on the Host; the Relay is stateless.
    public private(set) var sharedTerminalLayouts: [String: SharedTerminalLayout] = [:]

    /// One cold-start persistence read per live session. Until that read
    /// finishes, the session is deliberately absent from
    /// `sharedTerminalLayouts`: absence means "unknown", while an explicit
    /// entry with an empty right side means "authoritatively unsplit".
    @ObservationIgnored
    private var sharedTerminalLayoutInitializationTasks: [String: Task<Void, Never>] = [:]

    /// Task for periodic session validation
    private var sessionValidationTask: Task<Void, Never>?

    /// Task for reconciling process-detected agent panes. Kept separate from
    /// tmux metadata validation so agent scans can run less frequently.
    @ObservationIgnored
    private var agentReconciliationTask: Task<Void, Never>?

    /// Pane sessions created by process detection rather than a plugin state
    /// event. Only these sessions may be removed by a later process scan.
    @ObservationIgnored
    private var processDetectedPaneIds: Set<String> = []

    /// SessionEnd can arrive before process exit. Suppress only observed old
    /// processes, never a new agent started in the same pane between scans.
    @ObservationIgnored
    private var suppressedAgentProcessIDs: [String: Set<String>] = [:]

    @ObservationIgnored
    private var lastDetectedAgentProcesses: [String: TmuxService.DetectedAgentPane] = [:]

    /// Called when session metadata (description, color, or emoji) changes,
    /// to push updated state to viewers.
    public var onSessionMetadataChanged: (@MainActor @Sendable () async -> Void)?

    /// Called after a tmux refresh prunes stale pane entries or shared layout
    /// window IDs. The coordinator broadcasts the resulting snapshot.
    public var onPaneStatesPruned: (@MainActor @Sendable () async -> Void)?

    /// Called only when process reconciliation changes a pane's terminal/agent
    /// classification. The coordinator updates sleep prevention and viewers.
    public var onAgentProcessReconciliationChanged: (@MainActor @Sendable () async -> Void)?

    /// Called when cold-start/background-session hydration establishes a new
    /// authoritative terminal layout, so connected Viewers receive it without
    /// waiting for another tmux change.
    public var onSharedTerminalLayoutInitialized: (@MainActor @Sendable () async -> Void)?

    /// Interval between session validation checks (in seconds)
    private let validationInterval: TimeInterval = 5

    /// Agent process trees change far less often than pane metadata. A longer
    /// cadence avoids needless `tmux` + `ps` subprocesses while bounding stale
    /// icon correction to ten seconds.
    static let agentReconciliationInterval: Duration = .seconds(10)

    @ObservationIgnored
    @Dependency(ProcessRunner.self) private var processRunner

    @ObservationIgnored
    @Dependency(LayoutStore.self) private var layoutStore

    private let logger = Logger(label: "com.jicezeng.ctrlx.mirrorwindowmanager")
    private let settings: AppSettings
    private let tmuxService: TmuxService

    /// Pane stream manager for sharing streams
    public var paneStreamManager: PaneStreamManager

    /// Editor session manager for prompt editing
    public let editorSessionManager: EditorSessionManager

    public init(
        settings: AppSettings,
        tmuxService: TmuxService,
        paneStreamManager: PaneStreamManager,
        editorSessionManager: EditorSessionManager
    ) {
        self.settings = settings
        self.tmuxService = tmuxService
        self.paneStreamManager = paneStreamManager
        self.editorSessionManager = editorSessionManager
    }

    // MARK: - Pane State Management

    /// Updates the pane states dictionary from tmux pane metadata.
    /// Creates new entries for newly discovered panes, updates metadata for existing panes,
    /// and removes entries for panes that no longer exist (cleaning up associated state).
    ///
    /// An empty `panes` argument is a legitimate signal that the tmux server has
    /// no panes (e.g. the user just closed the last session and the server
    /// exited). When that happens we must clear `paneStates` so the UI stops
    /// showing stale sessions; refusing to clear leaves the just-closed session
    /// pinned in the session list and tab bars indefinitely. The producer-side
    /// guards in `TmuxService.refreshPanes()` only set `panes = []` on
    /// confident server-down paths, so we trust them here. Surprising wipes
    /// are still observable via the warnings below and the producer-side logs.
    @discardableResult
    public func updatePaneStates(from panes: [PaneInfo]) -> Bool {
        if panes.isEmpty && !paneStates.isEmpty {
            logger.warning("updatePaneStates clearing non-empty state from empty panes", metadata: [
                "existingPaneCount": "\(paneStates.count)",
                "existingAgentSessionCount": "\(paneStates.values.filter { $0.agentSession != nil }.count)",
            ])
        }

        let currentPaneIds = Set(panes.map(\.paneId))
        var updatedStates = paneStates
        var changed = false

        // Update or create entries for current panes
        for pane in panes {
            if var state = updatedStates[pane.paneId] {
                if pane.updateMetadata(of: &state) {
                    updatedStates[pane.paneId] = state
                    changed = true
                }
            } else {
                updatedStates[pane.paneId] = pane.makePaneState()
                changed = true
            }
        }

        // Remove stale entries — but skip status-only minimal states.
        // `applyState` creates a `PaneState(paneId:agentSession:)` with
        // default-empty `sessionName` when a state arrives for a pane the
        // windowManager hasn't yet observed; the first refresh that sees the pane
        // fills in metadata. A refresh whose
        // `list-panes` snapshot was taken BEFORE the hook arrived (the subprocess
        // ran while MainActor was suspended) won't include that pane, and removing
        // the entry here would silently drop the SessionStart and lose the project
        // decoration. Empty `sessionName` is a reliable signal that no refresh has
        // confirmed the pane yet — refresh-derived entries always carry the tmux
        // session name. The next refresh that does see the pane confirms it; if the
        // pane truly never appears in tmux a follow-up hook with the same paneId
        // updates in place rather than accumulating.
        let stalePaneIds = updatedStates.keys.filter { paneId in
            guard !currentPaneIds.contains(paneId) else { return false }
            return updatedStates[paneId]?.sessionName.isEmpty == false
        }
        for paneId in stalePaneIds {
            processDetectedPaneIds.remove(paneId)
            suppressedAgentProcessIDs.removeValue(forKey: paneId)
            lastDetectedAgentProcesses.removeValue(forKey: paneId)
            updatedStates.removeValue(forKey: paneId)
            changed = true
        }
        if changed {
            paneStates = updatedStates
        }
        let liveWindowIdsBySession = Dictionary(grouping: updatedStates.values, by: \.sessionName)
            .mapValues { Set($0.map(\.stableWindowId)) }
        var reconciledLayouts: [String: SharedTerminalLayout] = [:]
        for (sessionName, layout) in sharedTerminalLayouts {
            guard
                let liveWindowIds = liveWindowIdsBySession[sessionName],
                liveWindowIds.contains(layout.leftWindowId)
            else { continue }

            let rightWindowIds = layout.rightWindowIds.filter {
                $0 != layout.leftWindowId && liveWindowIds.contains($0)
            }
            let selectedRightWindowId = layout.selectedRightWindowId
                .flatMap { rightWindowIds.contains($0) ? $0 : nil }
                ?? rightWindowIds.first
            if
                rightWindowIds == layout.rightWindowIds,
                selectedRightWindowId == layout.selectedRightWindowId {
                reconciledLayouts[sessionName] = layout
            } else {
                let revision = layout.revision == UInt64.max ? layout.revision : layout.revision + 1
                reconciledLayouts[sessionName] = SharedTerminalLayout(
                    leftWindowId: layout.leftWindowId,
                    rightWindowIds: rightWindowIds,
                    selectedRightWindowId: selectedRightWindowId,
                    splitRatio: layout.splitRatio,
                    revision: revision
                )
            }
        }
        let layoutChanged = reconciledLayouts != sharedTerminalLayouts
        if layoutChanged {
            sharedTerminalLayouts = reconciledLayouts
            changed = true
        }
        // Pruning can lower the pending count — e.g. `tmux kill-session` on a
        // pinned-Waiting terminal-only session, which has no SessionEnd hook of
        // its own — and the iOS badge is push-driven, so the host must emit the
        // decrease explicitly (issue #702; agent sessions get the same
        // treatment via `sessionEnded`).
        if !stalePaneIds.isEmpty || layoutChanged {
            Task { await onPaneStatesPruned?() }
        }
        return changed
    }

    /// Stores a validated logical layout and assigns its next Host revision.
    /// Equal requests are ignored so Viewer reconciliation cannot echo-loop.
    @discardableResult
    public func setSharedTerminalLayout(
        sessionName: String,
        leftWindowId: String,
        rightWindowIds: [String],
        selectedRightWindowId: String?,
        splitRatio: Double
    ) -> Bool {
        guard
            !sessionName.isEmpty,
            !leftWindowId.isEmpty,
            Set(rightWindowIds).count == rightWindowIds.count,
            !rightWindowIds.contains(leftWindowId),
            selectedRightWindowId.map(rightWindowIds.contains) ?? rightWindowIds.isEmpty
        else {
            return false
        }

        let ratio = min(max(splitRatio, 0.15), 0.85)
        if let current = sharedTerminalLayouts[sessionName],
           current.leftWindowId == leftWindowId,
           current.rightWindowIds == rightWindowIds,
           current.selectedRightWindowId == selectedRightWindowId,
           current.splitRatio == ratio {
            return false
        }

        let currentRevision = sharedTerminalLayouts[sessionName]?.revision ?? 0
        let revision = currentRevision == UInt64.max ? currentRevision : currentRevision + 1
        sharedTerminalLayouts[sessionName] = SharedTerminalLayout(
            leftWindowId: leftWindowId,
            rightWindowIds: rightWindowIds,
            selectedRightWindowId: selectedRightWindowId,
            splitRatio: ratio,
            revision: revision
        )
        return true
    }

    /// Establishes an explicit authoritative terminal layout for every live
    /// session, including sessions that are not selected in the Host UI.
    ///
    /// Persistence reads are single-flight per session. This method is cheap to
    /// call after every pane refresh; existing canonical layouts are never
    /// overwritten, so a layout changed by either peer always wins over a late
    /// disk read.
    public func initializeSharedTerminalLayoutsIfNeeded() {
        let windowsBySession = Dictionary(
            grouping: TmuxWindow.groupPanes(
                paneStates.values.filter { !$0.sessionName.isEmpty }
            ),
            by: \.sessionName
        )
        let liveSessionNames = Set(windowsBySession.keys)

        let staleTaskSessionNames = sharedTerminalLayoutInitializationTasks.keys.filter {
            !liveSessionNames.contains($0)
        }
        for sessionName in staleTaskSessionNames {
            sharedTerminalLayoutInitializationTasks.removeValue(forKey: sessionName)?.cancel()
        }

        for (sessionName, windows) in windowsBySession {
            guard
                sharedTerminalLayouts[sessionName] == nil,
                sharedTerminalLayoutInitializationTasks[sessionName] == nil
            else { continue }

            guard let folder = layoutFolder(in: windows) else {
                // tmux normally supplies a current path. If it temporarily
                // cannot, there is no persistence key to read, but the Host can
                // still remove ambiguity by publishing an explicit unsplit
                // layout for the live windows.
                if
                    let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                        from: nil,
                        sessionName: sessionName,
                        windows: terminalWindows(from: windows)
                    ),
                    setSharedTerminalLayout(
                        sessionName: request.sessionName,
                        leftWindowId: request.leftWindowId,
                        rightWindowIds: request.rightWindowIds,
                        selectedRightWindowId: request.selectedRightWindowId,
                        splitRatio: request.splitRatio
                    ) {
                    Task { await onSharedTerminalLayoutInitialized?() }
                }
                continue
            }

            let key = SavedFolderRecord.Key(host: SavedFolderRecord.localHost, folder: folder)
            sharedTerminalLayoutInitializationTasks[sessionName] = Task { [weak self] in
                guard let self else { return }
                let savedLayout = await layoutStore.record(key)?.layout
                guard !Task.isCancelled else { return }

                // Re-resolve from the current pane snapshot after the await. A
                // session can disappear, be renamed, or gain/lose windows while
                // the layout store is loading.
                let currentWindows = TmuxWindow.groupPanes(
                    paneStates.values.filter { $0.sessionName == sessionName }
                )
                defer { sharedTerminalLayoutInitializationTasks.removeValue(forKey: sessionName) }
                guard
                    !currentWindows.isEmpty,
                    sharedTerminalLayouts[sessionName] == nil,
                    layoutFolder(in: currentWindows) == folder
                else { return }

                let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(
                    from: savedLayout,
                    sessionName: sessionName,
                    windows: terminalWindows(from: currentWindows)
                )
                guard
                    let request,
                    setSharedTerminalLayout(
                        sessionName: request.sessionName,
                        leftWindowId: request.leftWindowId,
                        rightWindowIds: request.rightWindowIds,
                        selectedRightWindowId: request.selectedRightWindowId,
                        splitRatio: request.splitRatio
                    )
                else { return }

                await onSharedTerminalLayoutInitialized?()
            }
        }
    }

    private func terminalWindows(from windows: [TmuxWindow]) -> [LayoutSnapshotMapper.TerminalWindow] {
        windows.map {
            LayoutSnapshotMapper.TerminalWindow(
                index: $0.windowIndex,
                stableId: $0.stableId,
                isActive: $0.isWindowActive
            )
        }
    }

    private func layoutFolder(in windows: [TmuxWindow]) -> String? {
        guard
            let active = windows.first(where: \.isWindowActive) ?? windows.first,
            let pane = active.activePane
        else { return nil }
        return LayoutFolderKey.canonicalize(
            pane.agentSession?.detectedProjectPath ?? pane.currentPath
        )
    }

    // MARK: - Periodic Session Validation

    /// Starts a background task that periodically validates sessions against actual tmux panes.
    /// Sessions for panes that no longer exist are automatically removed.
    public func startPeriodicSessionValidation() {
        // Cancel any existing task
        sessionValidationTask?.cancel()

        sessionValidationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.validationInterval ?? 5))

                guard !Task.isCancelled, let self else { break }

                // Refresh panes and update state. Right-click context menus
                // host their own NSMenu (see StableContextMenu) so SwiftUI
                // reconciliation from this refresh no longer dismisses an
                // open popup mid-hover.
                let panes = await self.tmuxService.refreshPanes()
                self.updatePaneStates(from: panes)
                await self.refreshGitBranches()
            }
        }
    }

    /// Stops the periodic session validation task.
    public func stopPeriodicSessionValidation() {
        sessionValidationTask?.cancel()
        sessionValidationTask = nil
    }

    /// Periodically reconciles pane classifications against running agent
    /// processes. The provider is evaluated on every pass so enabling or
    /// disabling a plugin does not leave a stale process-name snapshot.
    public func startPeriodicAgentReconciliation(
        processNamesProvider: @escaping @MainActor @Sendable () -> [String: [String]]
    ) {
        agentReconciliationTask?.cancel()

        agentReconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.agentReconciliationInterval)

                guard !Task.isCancelled, let self else { break }
                await self.refreshDetectedAgentSessions(processNamesByPlugin: processNamesProvider())
            }
        }
    }

    /// Stops the periodic agent process reconciliation task.
    public func stopPeriodicAgentReconciliation() {
        agentReconciliationTask?.cancel()
        agentReconciliationTask = nil
    }

    func refreshDetectedAgentSessions(
        processNamesByPlugin: [String: [String]],
        refreshSnapshot: Bool = false
    ) async {
        guard let panes = await tmuxService.detectAgentPanesIfAvailable(
            processNamesByPlugin: processNamesByPlugin, refreshSnapshot: refreshSnapshot
        ), !Task.isCancelled else { return }
        if reconcileDetectedAgentSessions(panes) {
            await onAgentProcessReconciliationChanged?()
        }
    }

    // MARK: - Session Management

    /// Updates the agent session for the given pane ID, creating pane state if needed.
    /// Encapsulates the copy-mutate-reassign pattern for struct values in dictionaries.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - update: A closure that mutates the session
    private func updateSession(paneId: String, _ update: (inout AgentSession) -> Void) {
        var session = paneStates[paneId]?.agentSession ?? AgentSession(paneId: paneId)
        update(&session)
        if paneStates[paneId] != nil {
            paneStates[paneId]?.agentSession = session
        } else {
            // Pane not yet known from tmux refresh — create minimal state
            paneStates[paneId] = PaneState(paneId: paneId, agentSession: session)
        }
    }

    /// Reconciles process-detected agent panes without overriding plugin-owned
    /// sessions. New detections fill hook gaps; vanished processes only clear
    /// sessions that a previous process scan created.
    /// - Parameter panes: Mapping of pane ID to the detected plugin id and cwd.
    /// - Returns: whether any pane's terminal/agent classification or detected
    ///   metadata changed.
    @discardableResult
    public func reconcileDetectedAgentSessions(
        _ panes: [String: TmuxService.DetectedAgentPane]
    ) -> Bool {
        let detectedPaneIds = Set(panes.keys)
        var changed = false

        for (paneId, processIDs) in suppressedAgentProcessIDs {
            let remaining = processIDs.intersection(panes[paneId]?.processIDs ?? [])
            suppressedAgentProcessIDs[paneId] = remaining.isEmpty ? nil : remaining
        }
        lastDetectedAgentProcesses = panes

        // Clear only sessions created by this fallback. A transient `ps` miss
        // must never erase a plugin-owned working/waiting state.
        for paneId in processDetectedPaneIds.subtracting(detectedPaneIds) {
            processDetectedPaneIds.remove(paneId)
            changed = clearAgentSessionState(forPane: paneId) || changed
        }

        for (paneId, info) in panes {
            guard
                paneStates[paneId] != nil,
                !info.processIDs.isSubset(of: suppressedAgentProcessIDs[paneId] ?? [])
            else { continue }

            if processDetectedPaneIds.contains(paneId) {
                guard var session = paneStates[paneId]?.agentSession else {
                    processDetectedPaneIds.remove(paneId)
                    continue
                }
                guard
                    session.pluginID != info.pluginID
                    || session.detectedProjectPath != info.path
                else { continue }
                session.pluginID = info.pluginID
                session.detectedProjectPath = info.path
                paneStates[paneId]?.agentSession = session
                changed = true
            } else if paneStates[paneId]?.agentSession == nil {
                updateSession(paneId: paneId) { session in
                    session.detectedProjectPath = info.path
                    session.pluginID = info.pluginID
                }
                processDetectedPaneIds.insert(paneId)
                changed = true
            }
        }

        return changed
    }

    /// Ends the agent session on a pane: removes its `AgentSession` so the sidebar
    /// row reverts from the idle/working status indicator to the plain terminal
    /// glyph, and drops the pane's session-scoped guard state. This is the
    /// agent-blind equivalent of the legacy `claudeSession = nil` on `SessionEnd`;
    /// it's driven by the `.sessionEnded` app action (Claude's hook, or Codex's
    /// process-exit monitor), NOT by a `working == false` status (a `Stop` leaves
    /// the session alive and idle — only an end removes it). The pane state itself
    /// is kept (the terminal is still open); it's reclaimed separately when the
    /// pane closes.
    /// - Returns: whether a session was actually removed (so the caller can push
    ///   updated state to viewers only when something changed).
    @discardableResult
    public func endAgentSession(forPane paneId: String) -> Bool {
        guard let session = paneStates[paneId]?.agentSession else { return false }
        processDetectedPaneIds.remove(paneId)
        if let detected = lastDetectedAgentProcesses[paneId], detected.pluginID == session.pluginID {
            suppressedAgentProcessIDs[paneId] = detected.processIDs
        }
        return clearAgentSessionState(forPane: paneId)
    }

    private func clearAgentSessionState(forPane paneId: String) -> Bool {
        guard paneStates[paneId]?.agentSession != nil else { return false }
        paneStates[paneId]?.agentSession = nil
        // Drop the OTEL telemetry joined to this session (issue #597) so a fresh
        // session in the same pane doesn't inherit the prior meter / mode.
        paneStates[paneId]?.telemetry = nil
        paneStates[paneId]?.permissionMode = nil
        paneStates[paneId]?.permissionModeTrigger = nil
        paneStates[paneId]?.claudeSessionID = nil
        // The end-of-turn recap (issue #598) belongs to the session just ended.
        paneStates[paneId]?.recap = nil
        // So does any manual "Set State" override (issue #695): without this
        // the sidebar would keep showing the stale override on what is now a
        // plain terminal pane. Session-wide, matching how the override is
        // applied and cleared elsewhere.
        clearCLISessionState(forSessionOfPane: paneId)
        return true
    }

    // MARK: - OTEL Telemetry Join + Stamp (issue #597)

    /// Returns the pane currently bound to `sessionID` (the Claude `session.id`),
    /// or `nil` if no pane has registered that id yet.
    public func paneId(forClaudeSessionID sessionID: String) -> String? {
        paneStates.first(where: { $0.value.claudeSessionID == sessionID })?.key
    }

    /// Stamps accumulated OTEL telemetry onto the pane bound to `sessionID`.
    /// - Returns: the stamped pane id, or `nil` if no pane is bound to the id
    ///   (so the caller can skip the viewer push).
    @discardableResult
    public func applyTelemetry(_ telemetry: SessionTelemetry, forClaudeSessionID sessionID: String) -> String? {
        guard let paneId = paneId(forClaudeSessionID: sessionID) else { return nil }
        paneStates[paneId]?.telemetry = telemetry
        return paneId
    }

    /// Records a permission-mode change on the pane bound to `sessionID`.
    /// - Returns: the stamped pane id, or `nil` if no pane is bound to the id.
    @discardableResult
    public func applyPermissionMode(
        _ mode: String,
        trigger: String?,
        forClaudeSessionID sessionID: String
    ) -> String? {
        guard let paneId = paneId(forClaudeSessionID: sessionID) else { return nil }
        paneStates[paneId]?.permissionMode = mode
        paneStates[paneId]?.permissionModeTrigger = trigger
        return paneId
    }

    /// The project folder name for the pane bound to `sessionID`, used to label
    /// milestone notifications. Falls back to `nil` when unknown.
    public func projectName(forClaudeSessionID sessionID: String) -> String? {
        guard let paneId = paneId(forClaudeSessionID: sessionID) else { return nil }
        return paneStates[paneId]?.agentSession?.displayName
    }

    /// The detected project path for the pane bound to `sessionID` — the
    /// aggregation key for the cross-session usage store (issue #598). `nil` when
    /// no pane is bound or no project was detected.
    public func detectedProjectPath(forClaudeSessionID sessionID: String) -> String? {
        guard let paneId = paneId(forClaudeSessionID: sessionID) else { return nil }
        return paneStates[paneId]?.agentSession?.detectedProjectPath
    }

    /// Stamps an end-of-turn recap onto a pane by its tmux pane id (issue #598).
    /// Keyed by pane (not the Claude session.id) because the recap is built from
    /// the `doneWorking` plugin state, which is already pane-addressed.
    public func applyRecap(_ recap: SessionRecap, forPane paneId: String) {
        guard paneStates[paneId] != nil else { return }
        paneStates[paneId]?.recap = recap
    }

    // MARK: - Plugin State (in-process plugin runtime)

    /// Applies a session-state update produced by the in-process plugin runtime
    /// (spec §5, `PluginEvent.state`). This is the SOLE state driver: it ensures
    /// the pane has an `AgentSession` (so the pane registers as an active session
    /// and counts toward attention/sleep-prevention), then sets the session's
    /// `state` directly. `isWorking` / `needsAttention` are derived from it, and
    /// the open response form (if any) rides the `awaiting*` cases — so opening or
    /// retracting a form is just "the state changed", with no separate map.
    ///
    /// The pane is keyed by `tmuxPane`. Setting any state also clears a stale CLI
    /// override on this pane and its session siblings so plugin activity wins over
    /// a prior `session.set_state` from the CLI.
    ///
    /// - Parameters:
    ///   - pluginID: The plugin that produced the state (owns the session).
    ///   - sessionID: The plugin's opaque session id (informational here).
    ///   - state: The session's new `AgentState`.
    ///   - tmuxPane: The pane this state targets (the session key).
    ///   - projectPath: Optional project path, recorded on the session so the
    ///     sidebar can render a name before any tmux refresh tick.
    ///   - permissionMode: The session's current permission mode, when the
    ///     originating hook carried one (`UserPromptSubmit`/`PreToolUse`/
    ///     `PostToolUse`/`Stop`). `nil` leaves the existing value unchanged — this
    ///     is the hook-channel seed so a non-default starting mode shows its chip
    ///     without waiting for an OTEL `permission_mode_changed` (issue #597).
    public func applyState(
        pluginID: String,
        sessionID: String,
        state: AgentState,
        tmuxPane: String?,
        projectPath: String?,
        permissionMode: String? = nil
    ) {
        guard let paneId = tmuxPane, !paneId.isEmpty else {
            logger.debug("Dropping plugin state with no tmuxPane", metadata: [
                "pluginID": "\(pluginID)",
                "sessionID": "\(sessionID)",
            ])
            return
        }

        // A plugin state is authoritative. It upgrades a process-detected
        // session to plugin ownership and proves any prior end suppression stale.
        processDetectedPaneIds.remove(paneId)
        suppressedAgentProcessIDs.removeValue(forKey: paneId)

        // Ensure a session exists for this pane and set the state directly. Record
        // the project path so the sidebar has a name before the next tmux refresh
        // confirms the pane.
        updateSession(paneId: paneId) { session in
            session.pluginID = pluginID
            if let projectPath, !projectPath.isEmpty {
                session.detectedProjectPath = projectPath
            }
            session.state = state
        }

        // A new turn started — drop any end-of-turn recap (issue #598) so the
        // card doesn't linger over an active turn. A fresh `doneWorking` restamps
        // it from the updated telemetry.
        if case .working = state {
            paneStates[paneId]?.recap = nil
        }

        // Persist the hook `session_id` as the join key for the OTEL telemetry
        // channel (issue #597). When it changes (a new session via `/clear` or
        // resume) the accumulated meter belongs to the prior session, so reset it
        // — the next `api_request` for the new id repopulates a fresh meter.
        if paneStates[paneId]?.claudeSessionID != sessionID {
            paneStates[paneId]?.claudeSessionID = sessionID
            paneStates[paneId]?.telemetry = nil
            paneStates[paneId]?.permissionMode = nil
            paneStates[paneId]?.permissionModeTrigger = nil
        }

        // Seed the current permission mode from the hook channel (issue #597).
        // Only the four tool/prompt/stop events carry it; others pass nil, which
        // must NOT clobber a mode already known (incl. one just learned from an
        // OTEL `permission_mode_changed`). Stamped after the session-id reset above
        // so a fresh session's first hook wins. (`default` is stamped and renders
        // its own gray-shield chip; only a truly unknown/empty mode shows nothing.)
        if let permissionMode {
            paneStates[paneId]?.permissionMode = permissionMode
        }

        // Record arrival order for the "most recent activity" sort.
        lastActivityByPane[paneId] = Date()

        // A definitive state wins over any CLI-driven override so subsequent
        // plugin activity is reflected.
        clearCLISessionState(forSessionOfPane: paneId)
    }

    /// Updates the terminal title for a pane.
    /// - Parameters:
    ///   - paneId: The tmux pane ID
    ///   - title: The new terminal title
    public func updateTerminalTitle(paneId: String, title: String) {
        paneStates[paneId]?.terminalTitle = title
    }

    /// Updates the `OSC 9;4` progress signal for a pane. `.removed` clears it.
    /// Returns `true` if the stored value actually changed; the caller can use
    /// that to decide whether to push session state to viewers.
    @discardableResult
    public func setPaneProgress(_ progress: TerminalProgressState, for paneId: String) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        let normalized: TerminalProgressState? = progress == .removed ? nil : progress
        if paneStates[paneId]?.progress == normalized {
            return false
        }
        paneStates[paneId]?.progress = normalized
        return true
    }

    /// Set of pane IDs that have active agent sessions
    public var activeSessionPaneIds: Set<String> {
        Set(paneStates.filter { $0.value.agentSession != nil }.keys)
    }

    /// Number of sessions that need user attention: agent panes displayed as
    /// Waiting (the manual "Set State" override wins in both directions —
    /// issue #702) plus terminal-only sessions pinned to Waiting, counted once
    /// per session (`Collection.pendingSessionCount`). Matches the number of
    /// bell rows the menu bar dropdown shows.
    public var pendingSessionCount: Int {
        paneStates.values.pendingSessionCount
    }

    /// The `pendingSessionCount` high-water mark last observed by
    /// `pendingCountDecrease()`. Seeded at 0 (a fresh launch has no pending
    /// sessions; even if it did, the first call self-corrects).
    private var lastPendingCount = 0

    /// Returns the current `pendingSessionCount` *only when it has dropped*
    /// since the previous call, otherwise `nil` — and advances the high-water
    /// mark either way.
    ///
    /// The iOS app icon badge is driven solely by APNs pushes carrying a badge.
    /// A needs-attention *increase* always arrives with its own notification
    /// (Stop / permission / question), whose alert push carries the badge up;
    /// a *decrease* — the agent resumed, a session ended, or the user handled
    /// it on another device — has no notification of its own, so it is the only
    /// case that needs an explicit silent badge push. Reporting decreases only
    /// (and deduplicating against the high-water mark) keeps the badge in sync
    /// without flooding APNs' background-push budget on every state tick.
    ///
    /// Not `@discardableResult`: dropping the return value would advance the
    /// high-water mark *and* swallow the decrease, so callers must broadcast it.
    public func pendingCountDecrease() -> Int? {
        let count = pendingSessionCount
        defer { lastPendingCount = count }
        return count < lastPendingCount ? count : nil
    }

    /// All sessions sorted with attention-needing sessions first
    public var sortedSessions: [AgentSession] {
        paneStates.values
            .compactMap(\.agentSession)
            .sorted {
                if $0.needsAttention != $1.needsAttention {
                    return $0.needsAttention
                }
                return $0.paneId < $1.paneId
            }
    }

    // MARK: - Mark Handled

    /// When each pane last received a plugin state update, used for the
    /// "most recent activity" sidebar sort. The agent-blind `PluginEvent` carries
    /// no event timestamp (the trailing-event buffer was dropped, spec §16), so
    /// recency is sourced from state-arrival order instead — which matches the
    /// order the host received the events in.
    private var lastActivityByPane: [String: Date] = [:]

    /// The most recent plugin-state arrival time for a pane, if any.
    public func lastActivity(for paneId: String) -> Date? {
        lastActivityByPane[paneId]
    }

    /// Marks a session as handled (user has seen it). Only a finished session
    /// (`doneWorking`) goes idle; an `awaiting*` form is owed an explicit response
    /// so it survives viewing — the guard now lives inside `AgentSession.markHandled`.
    /// - Parameter paneId: The pane ID whose session should be marked handled
    public func markSessionHandled(paneId: String) {
        paneStates[paneId]?.agentSession?.markHandled()
    }

    // MARK: - CLI Session State Override

    /// Sets the CLI-driven session state override for a pane. Pass `nil` to
    /// clear the override and revert to whatever the underlying Claude session
    /// (or absence of one) reports. No-op if the pane isn't tracked yet —
    /// callers should refresh tmux state first so `sessionName` is populated;
    /// otherwise the session-wide hook clearing in `handleHookEvent` can't
    /// match siblings.
    /// - Parameters:
    ///   - state: The override to apply, or `nil` to clear.
    ///   - paneId: The pane to apply the override to.
    /// - Returns: `true` when an existing pane was updated.
    @discardableResult
    public func setCLISessionState(_ state: CLISessionState?, for paneId: String) -> Bool {
        guard paneStates[paneId] != nil else { return false }
        paneStates[paneId]?.cliSessionState = state
        return true
    }

    /// Applies a manual state override to every pane in a session, then pushes
    /// the change to connected viewers. Used by the "Set State" context menu
    /// (issue #695); `nil` clears the override, reverting to the agent-driven
    /// state. Unlike color/emoji this is NOT persisted to tmux — it's a transient
    /// override, and any later plugin state update (`applyState`) or agent
    /// session end (`endAgentSession`) clears it, so the live agent always wins
    /// over the manual choice. Applied to every pane so it survives switching
    /// windows and matches the session-wide clear in `clearCLISessionState`.
    /// - Parameters:
    ///   - state: The override to apply, or `nil` to clear.
    ///   - sessionName: The tmux session name.
    public func setCLISessionState(_ state: CLISessionState?, forSession sessionName: String) {
        for (paneId, paneState) in paneStates where paneState.sessionName == sessionName {
            paneStates[paneId]?.cliSessionState = state
        }
        Task { await onSessionMetadataChanged?() }
    }

    /// Clears the manual state override on `paneId` and every sibling pane in
    /// its session. The sidebar aggregates the override across every pane in
    /// the session (and `setCLISessionState(_:forSession:)` stamps them all),
    /// so a single-pane clear would leave a stale copy visible on a sibling.
    /// Falls back to just the pane when its session name isn't known yet.
    private func clearCLISessionState(forSessionOfPane paneId: String) {
        let sessionName = paneStates[paneId]?.sessionName
        if let sessionName, !sessionName.isEmpty {
            for (otherId, paneState) in paneStates where paneState.sessionName == sessionName {
                paneStates[otherId]?.cliSessionState = nil
            }
        } else {
            paneStates[paneId]?.cliSessionState = nil
        }
    }

    // MARK: - Yolo Mode

    /// Sets yolo mode for a pane's agent session.
    /// When enabled, auto-approvable permission requests are approved by the
    /// plugin path (the app calls `deliverResponse(.permission(.allow))` for an
    /// `isAutoApprovable` request on a yolo pane — spec §6), so this method only
    /// records the flag.
    /// - Parameters:
    ///   - enabled: Whether to enable or disable yolo mode
    ///   - paneId: The pane ID to set yolo mode for
    public func setYoloMode(enabled: Bool, for paneId: String) {
        if paneStates[paneId] != nil {
            paneStates[paneId]?.yoloMode = enabled
        } else {
            // Create minimal state if needed
            paneStates[paneId] = PaneState(paneId: paneId, yoloMode: enabled)
        }
    }

    /// Whether yolo mode is enabled for the given pane
    public func isYoloModeEnabled(for paneId: String) -> Bool {
        paneStates[paneId]?.yoloMode ?? false
    }

    // MARK: - Session Descriptions

    /// Sets a custom description for a session, updating every pane in every window
    /// of that session so the description survives switching windows/tabs.
    /// The description is persisted as a tmux user option so it survives app restarts.
    /// - Parameters:
    ///   - description: The description text, or nil to clear
    ///   - sessionName: The tmux session name
    public func setSessionDescription(_ description: String?, for sessionName: String) {
        let normalizedDescription = description?.isEmpty == true ? nil : description
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customDescription = normalizedDescription
        }
        Task { [tmuxService] in
            try? await tmuxService.setSessionDescription(normalizedDescription, for: sessionName)
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Session Colors

    /// Sets a custom color for a session, applied to every pane so it survives
    /// switching windows. Persisted as a tmux user option (see `TmuxService`).
    /// - Parameters:
    ///   - color: The color, or nil to clear
    ///   - sessionName: The tmux session name
    public func setSessionColor(_ color: SessionColor?, for sessionName: String) {
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customColor = color
        }
        Task { [tmuxService, logger] in
            do {
                try await tmuxService.setSessionColor(color, for: sessionName)
            } catch {
                logger.warning("Failed to persist session color", metadata: [
                    "session": "\(sessionName)",
                    "error": "\(error)",
                ])
            }
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Session Emoji

    /// Sets a custom emoji for a session, applied to every pane so it survives
    /// switching windows. Persisted as a tmux user option (see `TmuxService`).
    /// - Parameters:
    ///   - emoji: The emoji string, or nil/empty to clear
    ///   - sessionName: The tmux session name
    public func setSessionEmoji(_ emoji: String?, for sessionName: String) {
        let normalizedEmoji = emoji?.isEmpty == true ? nil : emoji
        // Optimistic local update for immediate UI feedback; tmux remains the source
        // of truth and the next refresh reconciles from it.
        for (paneId, state) in paneStates where state.sessionName == sessionName {
            paneStates[paneId]?.customEmoji = normalizedEmoji
        }
        Task { [tmuxService, logger] in
            do {
                try await tmuxService.setSessionEmoji(normalizedEmoji, for: sessionName)
            } catch {
                logger.warning("Failed to persist session emoji", metadata: [
                    "session": "\(sessionName)",
                    "error": "\(error)",
                ])
            }
            await onSessionMetadataChanged?()
        }
    }

    // MARK: - Git Branch Detection

    private static let gitPath = "/usr/bin/git"

    /// Refreshes git branch info for all panes that have a current path. The Git
    /// tab's changed-file badge (issue #573) is driven separately, straight off
    /// the per-session GitWorkbench store's `summary`; the sidebar branch keeps
    /// using a single cheap `git rev-parse` here rather than GitWorkbench's
    /// heavier `loadStatus()`.
    func refreshGitBranches() async {
        var panesForPath: [String: [String]] = [:]
        for (paneId, state) in paneStates {
            guard let path = state.currentPath, !path.isEmpty else { continue }
            panesForPath[path, default: []].append(paneId)
        }

        let branchesByPath = await withTaskGroup(
            of: (String, String?).self,
            returning: [(String, String?)].self
        ) { group in
            for path in panesForPath.keys {
                group.addTask { [processRunner] in
                    let branch = await Self.detectGitBranch(at: path, processRunner: processRunner)
                    return (path, branch)
                }
            }

            var result: [(String, String?)] = []
            for await (path, branch) in group {
                result.append((path, branch))
            }
            return result
        }

        // Re-read after the task group: this actor was re-entrant while git ran,
        // so starting from the pre-await dictionary could overwrite newer agent
        // or terminal state. Publish once, and only when a branch really changed.
        var updatedStates = paneStates
        var changed = false
        for (path, branch) in branchesByPath {
            for paneId in panesForPath[path] ?? [] {
                guard
                    var state = updatedStates[paneId],
                    state.currentPath == path,
                    state.gitBranch != branch
                else { continue }
                state.gitBranch = branch
                updatedStates[paneId] = state
                changed = true
            }
        }
        if changed {
            paneStates = updatedStates
        }
    }

    /// Detects the git branch for a given directory path.
    /// Returns nil if the path is not inside a git repository.
    private static func detectGitBranch(
        at path: String,
        processRunner: ProcessRunner
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard
            let result = try? await processRunner.run(
                gitPath,
                ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                nil,
                5
            ) else { return nil }

        guard result.isSuccess else { return nil }
        let branch = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty { return nil }
        // `git rev-parse --abbrev-ref HEAD` returns the literal "HEAD" when the
        // working copy is in a detached-HEAD state. Surface that explicitly
        // rather than showing "HEAD" in the sidebar.
        if branch == "HEAD" { return "(detached)" }
        return branch
    }

}

#if DEBUG
    extension MirrorWindowManager {
        /// SwiftUI-preview seam (DEBUG only): inject fully-formed pane states so a
        /// preview can render every row variant without driving the live tmux,
        /// hook, or OTEL pipelines. `paneStates` is otherwise `private(set)`; this
        /// is never called from shipping code.
        func setPaneStatesForPreview(_ states: [PaneState]) {
            for state in states {
                paneStates[state.paneId] = state
            }
        }
    }
#endif
