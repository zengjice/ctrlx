import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func recordWorkflowBridge(_ event: PluginEvent, peer: PluginIngressPeer) async throws {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard
            event.workflowBridgeVersion != nil, let paneID = event.tmuxPane,
            let store = agentWorkflowStore, let registry = pluginRegistry,
            registry.core(event.pluginID) is any AgentWorkflowProviding else { return }
        guard try await !store.hasBridgeObservation(event, peer: peer) else { return }
        guard
            let detected = await tmuxService.detectAgentPanesIfAvailable(
                processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true
            ),
            let candidate = detected[paneID], candidate.pluginID == event.pluginID,
            candidate.processIDs.count == 1,
            let process = candidate.processIDs.first, let pid = Int32(process),
            let runtime = identities.runtimeID(process) else { return }
        try await store.recordBridge(event, processID: pid, runtimeID: runtime, peer: peer)
    }

    func scanWorkflowInstances(previous: [AgentWorkflowInstance], hostID: UUID) async throws -> [AgentWorkflowObservation] {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard let registry = pluginRegistry else { throw AgentWorkflowError("Agent plugins are not ready.") }
        await windowManager.refreshDetectedAgentSessions(processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true)
        guard
            let detected = await tmuxService.detectAgentPanesIfAvailable(
                processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true
            ) else { throw AgentWorkflowError("Cannot inspect Agent processes. The previous catalog was retained.") }

        var observations: [AgentWorkflowObservation] = []
        for paneID in detected.keys.sorted() {
            try Task.checkCancellation()
            guard let candidate = detected[paneID] else { continue }
            guard
                registry.core(candidate.pluginID) is any AgentWorkflowProviding,
                candidate.processIDs.count == 1,
                let process = candidate.processIDs.first, let pid = Int32(process),
                let runtime = identities.runtimeID(process),
                let pane = windowManager.paneStates[paneID],
                let native = await identities.load(paneID),
                native.matches(pane: pane, detected: candidate, runtimeID: runtime),
                pane.claudeSessionID == native.source.sessionID,
                let provider = registry.core(candidate.pluginID) as? any AgentWorkflowProviding else {
                // Temporarily missing native evidence must not assign a new UUID
                // when the same live process is verified on a later refresh.
                if
                    let known = previous.first(where: {
                        $0.paneID == paneID && $0.pluginID == candidate.pluginID
                            && candidate.processIDs.contains(String($0.processID))
                            && identities.runtimeID(String($0.processID)) == $0.processRuntimeID
                    }) {
                    var observation = AgentWorkflowObservation(known)
                    observation.readiness = .unavailable
                    observations.append(observation)
                }
                continue
            }
            let captured = try await tmuxService.captureWorkspacePane(target: paneID)
            let instance = AgentWorkflowInstance(
                hostID: hostID, pluginID: candidate.pluginID,
                processID: pid, processRuntimeID: runtime, workspacePane: captured.identity,
                paneID: paneID, conversationID: native.source.sessionID,
                displayName: "\(pane.sessionName) · \(pane.windowName)",
                workingDirectory: captured.info.currentPath,
                capabilities: provider.workflowCapabilities, readiness: .unavailable
            )
            try observations.append(AgentWorkflowObservation(await inspectWorkflowInput(instance)))
        }
        return observations
    }
}
