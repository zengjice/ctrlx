import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

struct AgentWorkflowBridgeEvidence: Codable, Equatable, Sendable {
    let pluginID: String
    let conversationID: String
    let paneID: String
    let processID: Int32
    let processRuntimeID: String
    let version: Int

    func matches(_ instance: AgentWorkflowInstance) -> Bool {
        pluginID == instance.pluginID && conversationID == instance.conversationID
            && paneID == instance.paneID && processID == instance.processID
            && processRuntimeID == instance.processRuntimeID
    }

    var issue: String? {
        guard version != PluginWorkflowHook.bridgeVersion else { return nil }
        return "This Agent's hook does not support the current workflow protocol. Update its CtrlX plugin and restart the Agent."
    }
}

extension AgentWorkflowStore {
    func bridgeIssue(for instance: AgentWorkflowInstance) throws -> String? {
        guard let evidence = try load().bridgeEvidence?.first(where: { $0.matches(instance) }) else {
            return "This Agent has not confirmed its workflow hook. Update its CtrlX plugin, then restart the Agent or submit a normal prompt before starting a workflow."
        }
        return evidence.issue
    }

    func hasBridgeObservation(_ event: PluginEvent, peer: PluginIngressPeer) throws -> Bool {
        try load().bridgeEvidence?.contains {
            $0.pluginID == event.pluginID && $0.conversationID == event.sessionID
                && $0.paneID == event.tmuxPane && $0.version == event.workflowBridgeVersion
                && peer.contains(processID: $0.processID, runtimeID: $0.processRuntimeID)
        } == true
    }

    /// The caller resolves the Agent root from the current process snapshot.
    /// SessionStart may arrive before the native conversation enters the catalog.
    @discardableResult
    func recordBridge(_ event: PluginEvent, processID: Int32, runtimeID: String, peer: PluginIngressPeer) throws -> Bool {
        guard
            let version = event.workflowBridgeVersion, version >= 0,
            let paneID = event.tmuxPane, !paneID.isEmpty,
            !event.pluginID.isEmpty, !event.sessionID.isEmpty,
            peer.contains(processID: processID, runtimeID: runtimeID) else { return false }
        let evidence = AgentWorkflowBridgeEvidence(
            pluginID: event.pluginID, conversationID: event.sessionID, paneID: paneID,
            processID: processID, processRuntimeID: runtimeID, version: version
        )
        var updated = try load()
        var entries = updated.bridgeEvidence ?? []
        if let index = entries.firstIndex(where: { $0.paneID == paneID }) {
            guard entries[index] != evidence else { return true }
            entries[index] = evidence
        } else {
            entries.append(evidence)
        }
        updated.bridgeEvidence = entries
        if let issue = evidence.issue {
            for index in updated.runs.indices where !updated.runs[index].status.isTerminal
                && updated.runs[index].instances.contains(where: { evidence.matches($0) }) {
                var execution = try AgentWorkflowExecution(validating: updated.runs[index])
                execution.pause(reason: issue)
                updated.runs[index] = execution.run
            }
        }
        try commit(updated)
        return true
    }
}
