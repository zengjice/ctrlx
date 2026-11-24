import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func recordWorkflowBridge(_ event: PluginEvent, peer: PluginIngressPeer) async throws {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard
            event.workflowBridgeVersion != nil, let paneID = event.tmuxPane,
            let catalog = agentRuntimeCatalog, let registry = pluginRegistry,
            registry.core(event.pluginID) is any AgentWorkflowProviding else { return }
        guard await !catalog.hasBridgeObservation(event, peer: peer) else { return }
        guard
            let detected = await tmuxService.detectAgentPanesIfAvailable(
                processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true
            ),
            let candidate = detected[paneID], candidate.pluginID == event.pluginID,
            candidate.processIDs.count == 1,
            let process = candidate.processIDs.first, let pid = Int32(process),
            let runtime = identities.runtimeID(process) else { return }
        try await catalog.recordBridge(event, processID: pid, runtimeID: runtime, peer: peer)
    }

    func scanWorkflowInstances(previous: [AgentWorkflowInstance], hostID: UUID) async throws -> [AgentWorkflowObservation] {
        @Dependency(AgentSessionIdentityClient.self) var identities
        guard let registry = pluginRegistry else { throw AgentWorkflowError("Agent plugins are not ready.") }
        guard
            let detected = await windowManager.refreshDetectedAgentSessions(
                processNamesByPlugin: registry.processNamesByPlugin, refreshSnapshot: true
            ) else {
            try Task.checkCancellation()
            throw AgentWorkflowInspectionUnavailable()
        }

        var observations: [AgentWorkflowObservation] = []
        var instances: [AgentWorkflowInstance] = []
        for paneID in detected.keys.sorted() {
            try Task.checkCancellation()
            guard let candidate = detected[paneID] else { continue }
            guard
                let provider = registry.core(candidate.pluginID) as? any AgentWorkflowProviding,
                candidate.processIDs.count == 1,
                let pane = windowManager.paneStates[paneID] else { continue }
            let captured = try await captureAgentBinding(paneID: paneID, detected: candidate)
            let binding = captured.binding
            guard let pid = Int32(binding.processID) else { continue }
            let known = previous.first { binding.matches($0) }
            let native = await identities.currentIdentity(in: pane, detected: candidate)
            let conversation: String
            if
                let native, binding.matches(native),
                windowManager.paneStates[paneID].flatMap(AgentForkSource.init(pane:)) == native.source {
                conversation = native.source.sessionID
            } else if CodexProcessSessionReader.supports(pluginID: candidate.pluginID), known?.conversationID.isEmpty ?? true {
                // A fresh Codex process creates its first native record only
                // after input. Its first authenticated task receipt binds it.
                conversation = ""
            } else {
                if let known {
                    var observation = AgentWorkflowObservation(known)
                    observation.readiness = .unavailable
                    observation.inputIssue = nil
                    observations.append(observation)
                }
                continue
            }
            let instance = AgentWorkflowInstance(
                id: known?.id ?? UUID(), hostID: hostID, pluginID: candidate.pluginID,
                processID: pid, processRuntimeID: binding.runtimeID, workspacePane: binding.workspacePane,
                paneID: paneID, conversationID: conversation,
                displayName: "\(pane.sessionName) · \(pane.windowName)",
                workingDirectory: captured.info.currentPath,
                capabilities: provider.workflowCapabilities, readiness: .unavailable
            )
            // This binding and conversation were already verified above.
            try instances.append(await inspectWorkflowCapabilities(instance, provider: provider))
        }
        for offset in stride(from: 0, to: instances.count, by: 4) {
            try await withThrowingTaskGroup(of: AgentWorkflowInstance.self) { group in
                for instance in instances.dropFirst(offset).prefix(4) {
                    group.addTask { try await self.inspectWorkflowReadiness(instance) }
                }
                for try await live in group {
                    guard
                        let pane = windowManager.paneStates[live.paneID],
                        pane.workspaceIdentity?.isSamePane(as: live.workspacePane) != false,
                        live.conversationID.isEmpty || pane.claudeSessionID == live.conversationID,
                        identities.runtimeID(String(live.processID)) == live.processRuntimeID else {
                        throw AgentWorkflowCatalogChanged()
                    }
                    observations.append(AgentWorkflowObservation(live))
                }
            }
        }
        return observations.sorted { $0.paneID < $1.paneID }
    }
}
