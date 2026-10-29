import CtrlxNetworking
import CtrlxSimulatorProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    /// Neither a cached conversation UUID nor a caller-supplied pane is authority.
    func resourceIdentity(for owner: SimulatorOwner) async -> AgentResourceIdentity? {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard
            let registry = pluginRegistry, let hostID = workspaceRecovery?.hostID,
            identities.runtimeID(String(owner.pid)) == owner.key else { return nil }
        await windowManager.refreshDetectedAgentSessions(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true)
        guard
            let detected = await tmuxService.detectAgentPanesIfAvailable(
                processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true
            ) else { return nil }
        let candidates = detected.filter { $0.value.processIDs == [String(owner.pid)] }
        guard
            candidates.count == 1, let (paneID, process) = candidates.first,
            let pane = windowManager.paneStates[paneID],
            let native = await identities.load(paneID),
            native.matches(pane: pane, detected: process, runtimeID: owner.key),
            pane.claudeSessionID == native.source.sessionID else { return nil }
        // /new can replace the conversation without replacing its process.
        if process.pluginID == "codex", await identities.codexSessionID(String(owner.pid), owner.key) != native.source.sessionID {
            return nil
        }
        guard
            let captured = try? await tmuxService.captureWorkspacePane(target: paneID),
            captured.identity.isSamePane(as: native.source.workspaceIdentity),
            identities.runtimeID(String(owner.pid)) == owner.key,
            windowManager.paneStates[paneID]?.claudeSessionID == native.source.sessionID else { return nil }
        return AgentResourceIdentity(
            hostID: hostID,
            pane: captured.identity,
            pluginID: process.pluginID,
            conversationID: native.source.sessionID
        )
    }
}
