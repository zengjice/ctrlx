import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies

extension AppCoordinator {
    func acceptsSessionEnd(_ context: AgentSessionEndContext, peer: PluginIngressPeer?) async -> Bool {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard let registry = pluginRegistry, context.matches(windowManager.paneStates[context.pane.paneId]) else { return false }
        guard
            let detected = await tmuxService.detectAgentPanesIfAvailable(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true),
            context.accepts(detected: detected[context.pane.paneId], peer: peer, runtimeID: identities.runtimeID) else { return false }
        return context.matches(windowManager.paneStates[context.pane.paneId])
    }

    func captureAgentBinding(paneID: String, detected: TmuxService.DetectedAgentPane) async throws -> (binding: AgentProcessBinding, info: PaneInfo) {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard
            detected.processIDs.count == 1, let pid = detected.processIDs.first,
            let runtime = identities.runtimeID(pid) else {
            throw AgentForkError("Cannot verify the Agent's current process.")
        }
        let captured = try await tmuxService.captureWorkspacePane(target: paneID)
        guard
            let binding = AgentProcessBinding(paneID: paneID, workspacePane: captured.identity, detected: detected, runtimeID: identities.runtimeID),
            binding.runtimeID == runtime else {
            throw AgentForkError("The Agent process changed.")
        }
        return (binding, captured.info)
    }
}
