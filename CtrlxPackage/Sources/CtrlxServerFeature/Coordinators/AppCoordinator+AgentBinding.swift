import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies

extension AppCoordinator {
    func agentID(forPane paneID: String?) -> AgentID? {
        guard
            let hostID = workspaceRecovery?.hostID, let paneID,
            let pane = windowManager.paneStates[paneID]?.workspaceIdentity else { return nil }
        return .init(hostID: hostID, paneID: pane.paneID)
    }

    var currentPluginEventIsValid: Bool {
        guard let context = AgentEventContext.current else { return true }
        @Dependency(AgentSessionIdentityClient.self) var identities
        return context.matches(windowManager.paneStates[context.binding.paneID], runtimeID: identities.runtimeID)
    }

    func withCurrentPluginEvent(_ event: PluginEvent, peer: PluginIngressPeer?, operation: @escaping @Sendable () async -> Void) async {
        guard let peer, let paneID = event.tmuxPane, let registry = pluginRegistry else { return }
        guard windowManager.paneStates[paneID] != nil else { return }
        let previous = windowManager.currentAgentBinding(forPane: paneID)
        if
            previous?.pluginID != event.pluginID || previous.flatMap({ binding in
                Int32(binding.processID).map { peer.contains(processID: $0, runtimeID: binding.runtimeID) }
            }) != true {
            await windowManager.refreshDetectedAgentSessions(
                processNamesByPlugin: registry.processNamesByPlugin,
                refreshSnapshot: event.conversationStarted == true || event.workflow?.kind == .submitted
            )
        }
        guard
            let binding = windowManager.currentAgentBinding(forPane: paneID),
            binding.pluginID == event.pluginID, let pid = Int32(binding.processID),
            peer.contains(processID: pid, runtimeID: binding.runtimeID) else { return }
        @Dependency(AgentSessionIdentityClient.self) var identities
        var nativeConversationID: String?
        if event.pluginID == "codex", windowManager.paneStates[paneID]?.claudeSessionID != event.sessionID {
            nativeConversationID = await identities.codexSessionID(binding.processID, binding.runtimeID)
        }
        guard let context = windowManager.acceptCurrentEvent(event, binding: binding, peer: peer, nativeConversationID: nativeConversationID) else { return }
        await AgentEventContext.$current.withValue(context) { await operation() }
    }

    func capturePluginEventOrigin(pluginID: String, paneID: String) -> PluginEventOrigin? {
        guard
            let binding = windowManager.recordedAgentBinding(forPane: paneID), binding.pluginID == pluginID,
            let conversationID = windowManager.paneStates[paneID]?.claudeSessionID else { return nil }
        return .init(pluginID: pluginID, paneID: paneID, workspacePane: binding.workspacePane, conversationID: conversationID, processID: binding.processID, runtimeID: binding.runtimeID)
    }

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
