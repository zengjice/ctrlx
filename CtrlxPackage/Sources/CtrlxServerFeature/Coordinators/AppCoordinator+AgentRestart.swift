import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies

extension AppCoordinator {
    func makeAgentRestartService() -> AgentRestartService {
        AgentRestartService(
            capture: { [weak self] request, workspace in
                guard let self else { throw AgentRestartError("Host is shutting down.") }
                return try await captureAgentRestartIdentity(request, workspace: workspace)
            },
            core: { [weak self] in self?.pluginRegistry?.core($0) as? any AgentSessionResuming },
            resume: { [weak self] proof, command in
                guard let self else { throw AgentRestartError("Host is shutting down.") }
                try await tmuxService.restartAgent(proof, command: command) { [weak self] in
                    guard let self else { throw AgentRestartError("Host is shutting down.") }
                    let current = try await captureAgentRestartIdentity(.init(source: proof.source, runtimeID: proof.runtimeID), workspace: proof.source.workspaceIdentity)
                    guard current.processID == proof.processID, current.runtimeID == proof.runtimeID else {
                        throw AgentRestartError("The Agent process changed before exit.")
                    }
                }
                windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
                await refreshAgentCommandIdentity()
                await connectedViewerManager?.pushSessionStateToAll()
            }
        )
    }

    func restartAgentSession(_ request: RestartAgentSession, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws {
        try await agentRestartService.restart(request, expectedWorkspacePane: expectedWorkspacePane)
    }

    private func captureAgentRestartIdentity(_ request: RestartAgentSession, workspace: WorkspacePaneIdentity?) async throws -> AgentSessionIdentity {
        @Dependency(AgentSessionIdentityClient.self) var identities
        windowManager.updatePaneStates(from: await tmuxService.refreshPanes())
        await refreshAgentCommandIdentity()
        guard
            let registry = pluginRegistry,
            let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true),
            let process = detected[request.source.paneID], let state = windowManager.paneStates[request.source.paneID],
            let native = await identities.currentIdentity(in: state, detected: process), request.matches(native.source, runtimeID: native.runtimeID),
            workspace == nil || workspace?.isSamePane(as: native.source.workspaceIdentity) == true else {
            throw AgentRestartError("The Agent conversation or terminal changed, or its identity is unverified. Reopen the current tab's menu.")
        }
        if process.pluginID == "codex", await identities.codexSessionID(native.processID, native.runtimeID) != native.source.sessionID {
            throw AgentRestartError("The active Codex conversation changed. Reopen its tab's menu.")
        }
        let captured = try await captureAgentBinding(paneID: native.source.paneID, detected: process)
        guard
            captured.binding.matches(native), captured.info.currentPath == native.source.workingDirectory,
            identities.runtimeID(native.processID) == native.runtimeID,
            windowManager.paneStates[native.source.paneID].flatMap(AgentForkSource.init(pane:)) == native.source else {
            throw AgentRestartError("The Agent process or directory changed before restart.")
        }
        return native
    }
}
