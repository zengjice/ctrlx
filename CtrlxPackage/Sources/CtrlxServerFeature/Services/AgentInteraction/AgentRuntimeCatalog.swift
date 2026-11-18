import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// One live directory shared by conversation and orchestration clients. A failed
/// scan never replaces a valid directory with an empty one.
actor AgentRuntimeCatalog {
    let hostID: UUID
    private let scan: @Sendable ([AgentWorkflowInstance]) async throws -> [AgentWorkflowObservation]
    private var instances: [AgentWorkflowInstance] = []
    private var refresh: Task<[AgentWorkflowInstance], Error>?
    private let bridgeFile: URL?
    private var bridges: [AgentWorkflowBridgeEvidence] = []

    init(hostID: UUID, bridgeFile: URL? = nil, scan: @escaping @Sendable ([AgentWorkflowInstance]) async throws -> [AgentWorkflowObservation]) {
        self.hostID = hostID
        self.bridgeFile = bridgeFile
        self.scan = scan
    }

    func loadBridges() throws {
        guard let bridgeFile, FileManager.default.fileExists(atPath: bridgeFile.path) else { return }
        bridges = try JSONDecoder().decode([AgentWorkflowBridgeEvidence].self, from: Data(contentsOf: bridgeFile))
    }

    func seedBridges(_ saved: [AgentWorkflowBridgeEvidence]) throws {
        var updated = bridges
        for entry in saved where !updated.contains(where: { $0.paneID == entry.paneID }) {
            updated.append(entry)
        }
        if updated != bridges {
            try saveBridges(updated)
        }
    }

    func snapshot(refresh: Bool = false) async throws -> [AgentWorkflowInstance] {
        if !refresh {
            return instances
        }
        if let refresh = self.refresh {
            return try await refresh.value
        }
        let work = Task { try await self.refreshInstances() }
        self.refresh = work
        defer { self.refresh = nil }
        return try await work.value
    }

    private func refreshInstances() async throws -> [AgentWorkflowInstance] {
        let observations = try await scan(instances)
        var panes = Set<UUID>()
        var processes = Set<Int32>()
        let next = try observations.map { observation in
            guard
                observation.processID > 1, !observation.processRuntimeID.isEmpty,
                !observation.pluginID.isEmpty, !observation.paneID.isEmpty,
                !observation.conversationID.isEmpty || CodexProcessSessionReader.supports(pluginID: observation.pluginID),
                panes.insert(observation.workspacePane.paneID).inserted,
                processes.insert(observation.processID).inserted else {
                throw AgentWorkflowError("Cannot register ambiguous or unverified Agent processes.")
            }
            let previous = instances.first { observation.matchesProcess($0) }
            if observation.conversationID.isEmpty, let previous, !previous.conversationID.isEmpty {
                throw AgentWorkflowCatalogChanged()
            }
            return observation.instance(hostID: hostID, id: previous?.id ?? UUID())
        }
        instances = next
        return next
    }

    func confirm(_ instance: AgentWorkflowInstance) {
        guard let index = instances.firstIndex(where: { $0.matchesProcess(instance) }) else { return }
        instances[index] = instance
    }

    func recordBridge(_ event: PluginEvent, processID: Int32, runtimeID: String, peer: PluginIngressPeer) throws {
        guard
            let version = event.workflowBridgeVersion, version >= 0,
            let paneID = event.tmuxPane, !paneID.isEmpty, !event.pluginID.isEmpty, !event.sessionID.isEmpty,
            peer.contains(processID: processID, runtimeID: runtimeID) else { return }
        let evidence = AgentWorkflowBridgeEvidence(pluginID: event.pluginID, conversationID: event.sessionID, paneID: paneID, processID: processID, processRuntimeID: runtimeID, version: version)
        if bridges.contains(evidence) {
            return
        }
        var updated = bridges.filter { $0.paneID != paneID }
        updated.append(evidence)
        try saveBridges(updated)
    }

    private func saveBridges(_ updated: [AgentWorkflowBridgeEvidence]) throws {
        if let bridgeFile {
            try FileManager.default.createDirectory(at: bridgeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: bridgeFile, options: .atomic)
        }
        bridges = updated
    }

    func hasBridgeObservation(_ event: PluginEvent, peer: PluginIngressPeer) -> Bool {
        bridges.contains {
            $0.pluginID == event.pluginID && $0.conversationID == event.sessionID
                && $0.paneID == event.tmuxPane && $0.version == event.workflowBridgeVersion
                && peer.contains(processID: $0.processID, runtimeID: $0.processRuntimeID)
        }
    }

    func bridgeIssue(for instance: AgentWorkflowInstance, allowsFirstSubmission: Bool) -> String? {
        if let evidence = bridges.first(where: { $0.matchesProcess(instance) }) {
            return evidence.issue
        }
        if allowsFirstSubmission, CodexProcessSessionReader.supports(pluginID: instance.pluginID) {
            return nil
        }
        return "This Agent has not confirmed its CtrlX hook. Refresh its hooks or submit a normal prompt before sending here."
    }
}
