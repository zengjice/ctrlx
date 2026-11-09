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
            let native = await identities.currentIdentity(in: pane, detected: process),
            native.runtimeID == owner.key else { return nil }
        // /new can replace the conversation without replacing its process.
        if process.pluginID == "codex", await identities.codexSessionID(String(owner.pid), owner.key) != native.source.sessionID {
            return nil
        }
        guard
            let captured = try? await captureAgentBinding(paneID: paneID, detected: process),
            captured.binding.matches(native),
            identities.runtimeID(String(owner.pid)) == owner.key,
            windowManager.paneStates[paneID].flatMap(AgentForkSource.init(pane:)) == native.source else { return nil }
        return AgentResourceIdentity(
            hostID: hostID,
            pane: captured.binding.workspacePane,
            pluginID: process.pluginID,
            conversationID: native.source.sessionID
        )
    }
}
