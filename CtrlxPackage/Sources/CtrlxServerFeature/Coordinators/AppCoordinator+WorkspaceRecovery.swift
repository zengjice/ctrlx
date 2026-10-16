import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func setupWorkspaceRecovery() async {
        @Dependency(WorkspaceRecoveryStore.self) var store
        @Dependency(WorkspaceRecoverySystem.self) var system
        let agents = WorkspaceAgentRecovery(
            core: { [weak self] in self?.pluginRegistry?.core($0) as? any AgentSessionResuming },
            mode: { [settings] in settings.workspaceRecoveryMode },
            refresh: { [weak self] in await self?.refreshAgentCommandIdentity() },
            version: { executable in
                @Dependency(WorkspaceAgentProcessClient.self) var processes
                return await processes.version(executable)
            },
            directoryExists: system.directoryExists,
            inspect: { [weak self] runtime in
                guard let self else { throw CancellationError() }
                var state = try await tmuxService.workspaceAgentPane(runtime)
                state.source = windowManager.paneStates[runtime].flatMap(AgentForkSource.init(pane:))
                return state
            },
            launch: { [tmuxService] runtime, pane, record, command in
                try await tmuxService.launchWorkspaceAgent(runtimeID: runtime, pane: pane, record: record, command: command)
            }
        )
        let recovery = WorkspaceRecoveryController(
            store: store, tmux: tmuxService.workspaceRecoveryClient(), system: system,
            mode: { [settings] in settings.workspaceRecoveryMode },
            captureExtras: { [weak self] snapshot in
                guard let self else { throw CancellationError() }
                return try await captureWorkspace(snapshot)
            },
            present: { [weak self] snapshot, live in
                guard let self else { throw CancellationError() }
                await presentWorkspace(snapshot, live: live)
            },
            resumeAgents: { snapshot, result, intent, save in
                try await agents.recover(snapshot, result: result, intent: intent, save: save)
            },
            captureViewer: { [weak self] snapshot in
                self?.captureViewerWorkspace(snapshot) ?? snapshot
            }
        )
        workspaceRecovery = recovery
        remoteEditorContentStore.onClear = { [weak self, weak recovery] key, submittedText in
            guard let self else { return }
            recoveredWorkspaceDrafts.captureRemote(editors: remoteEditorContentStore)
            recoveredWorkspaceDrafts.clearRemote(key, submittedText: submittedText)
            Task { await recovery?.checkpoint() }
        }
        tmuxService.workspaceCloseHandler = { [weak recovery] operation in
            guard let recovery else {
                _ = try await operation()
                return
            }
            try await recovery.performClose(operation)
        }
        await recovery.start()
        if recovery.phase != .failed || recovery.snapshot != nil {
            viewerWorkspaceRecovery.restore(settings.workspaceRecoveryMode == .disabled ? nil : recovery.snapshot?.viewerScenes, windows: detachedWindows)
            if settings.workspaceRecoveryMode != .disabled, let saved = recovery.snapshot {
                recoveredWorkspaceDrafts.restore(saved.drafts, sessions: recovery.liveState?.sessions ?? [])
            }
        }
        retainWorkspaceRecoveryHosts()
        windowManager.defersWorkspaceLayoutInitialization = false
        windowManager.initializeSharedTerminalLayoutsIfNeeded()
        workspaceRecoveryReady = true
    }

    private func captureWorkspace(_ source: WorkspaceRecoverySnapshot) async throws -> WorkspaceRecoverySnapshot {
        var snapshot = source
        snapshot.sessionOrder = settings.localSessionOrder.compactMap { name in source.sessions.first { $0.name == name }?.id }
        for store in [detachedWindows.mainTabs] + detachedWindows.workspaces.values.map(\.tabs) {
            store.capturePresentation?()
        }
        let live = workspaceRecovery?.liveState ?? WorkspaceTmuxState(serverID: source.serverID, sessions: source.sessions)
        recoveredWorkspaceDrafts.updateLocalRoutes(live.sessions)
        snapshot.drafts = recoveredWorkspaceDrafts.capture(editors: editorSessionManager, sessions: live.sessions)
        let captured = WorkspaceRecoveryPresentationMapper.captureLocal(windows: detachedWindows, sessions: live.sessions, mainID: detachedWindows.mainSceneID)
        snapshot.scenes = WorkspaceRecoveryPresentationMapper.preservingUnavailable(captured: captured, source: source, live: live)
        snapshot.fileTabs = WorkspaceRecoveryPresentationMapper.captureFiles(hostFileTabs.tabs, sessions: live.sessions)
        if source.recovery != nil {
            let livePanes = Set(live.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
            let savedPanes = Set(source.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id))
            snapshot.fileTabs += source.fileTabs.filter { savedPanes.contains($0.paneID) && !livePanes.contains($0.paneID) }
        }
        guard workspaceAgentDiscoveryComplete else { return snapshot }
        var capturedPanes: [UUID: WorkspaceRecoveryPane] = [:]
        for sessionIndex in snapshot.sessions.indices {
            for windowIndex in snapshot.sessions[sessionIndex].windows.indices {
                for paneIndex in snapshot.sessions[sessionIndex].windows[windowIndex].panes.indices {
                    var pane = snapshot.sessions[sessionIndex].windows[windowIndex].panes[paneIndex]
                    if let captured = capturedPanes[pane.id] {
                        snapshot.sessions[sessionIndex].windows[windowIndex].panes[paneIndex] = captured
                        continue
                    }
                    defer {
                        capturedPanes[pane.id] = pane
                        snapshot.sessions[sessionIndex].windows[windowIndex].panes[paneIndex] = pane
                    }
                    if source.recovery?.pendingAgentPaneIDs.contains(pane.id) == true {
                        continue
                    }
                    guard let state = windowManager.paneStates[pane.runtimeID] else { continue }
                    if let identity = AgentForkSource(pane: state), let core = pluginRegistry?.core(identity.pluginID) as? any AgentSessionResuming {
                        @Dependency(AgentSessionIdentityClient.self) var identities
                        guard
                            let proof = await identities.load(pane.runtimeID), proof.source == identity,
                            identities.runtimeID(proof.processID) == proof.runtimeID else {
                            pane.agent = nil
                            pane.unavailableAgentReason = "Waiting for verified Agent process identity."
                            continue
                        }
                        do {
                            if let cached = recoveryAgentDescriptors[pane.id], cached.source == identity, cached.runtimeID == proof.runtimeID {
                                pane.agent = cached.descriptor
                                pane.unavailableAgentReason = nil
                            } else {
                                @Dependency(WorkspaceAgentProcessClient.self) var processes
                                guard
                                    let names = pluginRegistry?.processNamesByPlugin[identity.pluginID],
                                    let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: [identity.pluginID: names], refreshSnapshot: true)?[identity.paneID],
                                    proof.matches(pane: state, detected: detected, runtimeID: identities.runtimeID(proof.processID)) else {
                                    throw WorkspaceRecoveryError("The Agent process no longer belongs to this pane.")
                                }
                                let invocation = try await processes.invocation(proof.processID, proof.runtimeID)
                                let descriptor = try await core.recoveryDescriptor(sessionID: identity.sessionID, projectPath: identity.workingDirectory, invocation: invocation)
                                guard windowManager.paneStates[pane.runtimeID].flatMap(AgentForkSource.init(pane:)) == identity else { continue }
                                recoveryAgentDescriptors[pane.id] = (identity, proof.runtimeID, descriptor)
                                pane.agent = descriptor
                                pane.unavailableAgentReason = nil
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Native history can appear after SessionStart. A failed
                            // read must be retried by the next checkpoint.
                            recoveryAgentDescriptors.removeValue(forKey: pane.id)
                            pane.agent = nil
                            pane.unavailableAgentReason = error.localizedDescription
                        }
                    } else if state.agentSession != nil {
                        pane.agent = nil
                        pane.unavailableAgentReason = "The Agent conversation or recovery capability could not be verified."
                    } else {
                        pane.agent = nil
                        pane.unavailableAgentReason = nil
                        recoveryAgentDescriptors.removeValue(forKey: pane.id)
                    }
                }
            }
        }
        return snapshot
    }

    private func captureViewerWorkspace(_ source: WorkspaceRecoverySnapshot) -> WorkspaceRecoverySnapshot {
        retainWorkspaceRecoveryHosts()
        recoveredWorkspaceDrafts.captureRemote(editors: remoteEditorContentStore)
        var snapshot = source
        snapshot.viewerScenes = viewerWorkspaceRecovery.capture(windows: detachedWindows)
        snapshot.drafts = source.drafts.filter { $0.hostID == nil } + recoveredWorkspaceDrafts.drafts.filter { $0.hostID != nil }
        return snapshot
    }

    func retainWorkspaceRecoveryHosts() {
        let hostIDs = Set(settings.pairedHosts.map(\.id))
        viewerWorkspaceRecovery.retainHosts(hostIDs, windows: detachedWindows)
        recoveredWorkspaceDrafts.retainHosts(hostIDs)
        remoteEditorContentStore.editedContents = remoteEditorContentStore.editedContents.filter { hostIDs.contains($0.key.hostID) }
    }

    private func presentWorkspace(_ snapshot: WorkspaceRecoverySnapshot, live: WorkspaceTmuxState) async {
        settings.pendingRecoverySessionNames = snapshot.recovery == nil ? [] : Set(snapshot.sessions.filter { saved in !live.sessions.contains { $0.id == saved.id } }.map(\.name))
        if !workspaceRecoveryReady {
            settings.setLocalSessionOrder(snapshot.sessionOrder.compactMap { id in
                live.sessions.first { $0.id == id }?.name ?? snapshot.sessions.first { $0.id == id }?.name
            })
        }
        windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
        recoveredWorkspaceDrafts.restore(snapshot.drafts, sessions: live.sessions)
        hostFileTabs.restore(snapshot.fileTabs, sessions: live.sessions, serverID: live.serverID)
        let alreadyPresented = detachedWindows.mainTabs.restoredRecoveryWindowIDs
        WorkspaceRecoveryPresentationMapper.restoreLocal(snapshot.scenes, live: live, windows: detachedWindows, files: hostFileTabs.tabs)
        viewerWorkspaceRecovery.restore(snapshot.viewerScenes, windows: detachedWindows)
        for session in live.sessions {
            guard
                let tabs = detachedWindows.mainTabs.local[session.name],
                windowManager.sharedTerminalLayouts[session.name] == nil || session.windows.contains(where: { !alreadyPresented.contains($0.id) }) else { continue }
            // The mapper has already resolved UUIDs to live IDs. Sharing this
            // applied state also preserves edits made before a partial retry.
            let layout = LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, includeHostFiles: true) { runtime in
                session.windows.first { $0.runtimeID == runtime }?.index
            }
            let resolved = session.windows.map {
                LayoutSnapshotMapper.TerminalWindow(index: $0.index, stableId: $0.runtimeID, isActive: session.selectedWindowID == $0.id)
            }
            let selection = detachedWindows.mainTabs.restoredSelection ?? detachedWindows.mainTabs.recoverySelection
            let preferred = selection?.sessionName == session.name ? selection?.windowID : nil
            if let request = LayoutSnapshotMapper.sharedTerminalLayoutRequest(from: layout, sessionName: session.name, windows: resolved, preferredLeftWindowId: preferred) {
                windowManager.setSharedTerminalLayout(
                    sessionName: request.sessionName,
                    leftWindowId: request.leftWindowId,
                    rightWindowIds: request.rightWindowIds,
                    selectedRightWindowId: request.selectedRightWindowId,
                    splitRatio: request.splitRatio
                )
            }
        }
    }
}
