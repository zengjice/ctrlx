import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

private struct ReplyTestParser: AgentWorkflowTranscriptParser {
    let turn: String
    var candidate: String
    var answer: String?
    mutating func updateCandidate(_ candidate: String) -> AgentWorkflowTranscriptOutcome? {
        self.candidate = candidate
        return answer == candidate && !candidate.isEmpty ? .succeeded(candidate) : nil
    }

    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome? {
        let record = try JSONDecoder().decode([String: String].self, from: line)
        guard record["turn"] == turn else { return nil }
        answer = record["final"]
        return updateCandidate(candidate)
    }
}

private actor ReplyTestProvider: AgentWorkflowProviding {
    nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 100_000)
    }

    nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: "test> ")
    }

    nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        ReplyTestParser(turn: nativeTurnID, candidate: candidate)
    }
}

@MainActor
final class AgentInteractionTestSupport {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-agent-interaction-\(UUID())")
    let hostID = UUID()
    var paths: CtrlxPaths {
        CtrlxPaths(stateRootOverride: root.appendingPathComponent("state"))
    }

    var observations: [AgentWorkflowObservation] = []
    var writes: [String] = []
    var launches: [UUID: WorkspacePaneIdentity] = [:]
    var lostCreateReply = false
    var lostWriteReply = false
    var beforeWrite: (() -> Void)?
    var beforeScan: (@MainActor @Sendable () async throws -> Void)?
    var scanCount = 0
    var workflowOccupied = false
    var workflowStore: AgentWorkflowStore?
    var replyProvider: @Sendable (String) async -> (any AgentWorkflowProviding)? = { _ in ReplyTestProvider() }
    var inspectReply: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance = { $0 }
    var synchronizeEvents: @Sendable () async throws -> Void = { }
    var catalog: AgentRuntimeCatalog!
    var interaction: AgentMessageService!
    var gate = AgentWorkflowInputGate()

    init(verificationTimeout: Duration = .seconds(60)) async throws {
        try await restartInteraction(verificationTimeout: verificationTimeout)
    }

    func restartInteraction(verificationTimeout: Duration = .seconds(60)) async throws {
        await interaction?.shutdown()
        catalog = AgentRuntimeCatalog(hostID: hostID) { [weak self] _ in
            guard let self else { throw CancellationError() }
            return try await self.scan()
        }
        let writer = AgentInputWriter(gate: gate, inspect: { [weak self] instance in
            guard let self, let current = observations.first(where: { $0.matchesProcess(instance) }) else { throw AgentWorkflowInspectionUnavailable() }
            return current.instance(hostID: hostID, id: instance.id)
        }, submit: { [weak self] _, file, _, authorize, _ in
            guard let self else { throw CancellationError() }
            beforeWrite?()
            try authorize { }
            try writes.append(String(contentsOf: file, encoding: .utf8))
            if lostWriteReply {
                throw AgentWorkflowError("Lost write reply")
            }
        })
        interaction = AgentMessageService(
            store: AgentMessageStore(directory: root.appendingPathComponent("messages")),
            catalog: catalog,
            writer: writer,
            temporaryDirectory: root.appendingPathComponent("input"),
            inspect: { [weak self] instance in
                guard let self else { throw CancellationError() }
                return try await inspectReply(instance)
            },
            occupied: { [weak self] id in
                if await self?.workflowOccupied == true {
                    return "Agent is participating in a Workflow."
                }
                if let store = await self?.workflowStore, try await store.snapshot().runs.contains(where: { !$0.status.isTerminal && $0.instances.contains { $0.agentID == id } }) {
                    return "Agent is participating in a Workflow."
                }
                return nil
            },
            provider: replyProvider,
            synchronizeEvents: { [weak self] in
                guard let self else { throw CancellationError() }
                try await synchronizeEvents()
            },
            verificationTimeout: verificationTimeout,
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        try await interaction.start()
    }

    private func scan() async throws -> [AgentWorkflowObservation] {
        scanCount += 1
        try await beforeScan?()
        return observations
    }

    func create(_ id: UUID, pluginID: String, title: String, directory: String) throws -> WorkspacePaneIdentity {
        let pane = WorkspacePaneIdentity(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID())
        let pid = Int32(100 + launches.count)
        launches[id] = pane
        observations.append(.init(
            pluginID: pluginID,
            processID: pid,
            processRuntimeID: "501:\(pid):100:0",
            workspacePane: pane,
            paneID: "%\(pid)",
            conversationID: UUID().uuidString,
            displayName: title,
            workingDirectory: directory,
            capabilities: .init(maximumInputBytes: 100_000),
            readiness: .ready
        ))
        if lostCreateReply {
            throw AgentWorkflowError("Lost creation reply")
        }
        return pane
    }

    func orbie(recovery: AgentRoleRecovery? = nil) async -> OrbieService {
        let service = OrbieService(store: .init(paths: paths, hostID: hostID), interaction: interaction, recovery: recovery, queryCommand: "ctrlx", launch: { [self] creation in
            try create(creation.id, pluginID: creation.pluginID, title: "Orbie", directory: creation.directory)
        }, locateCreation: { [self] in launches[$0] })
        await service.refresh()
        return service
    }

    func orbiters(source: AgentWorkflowInstance? = nil, recovery: AgentRoleRecovery? = nil) async -> OrbiterService {
        let service = OrbiterService(store: .init(paths: paths, hostID: hostID), interaction: interaction, recovery: recovery, enabled: { true }, forkSource: {
            guard let source else { throw AgentWorkflowError("Orbie is unavailable") }
            return source
        }, launch: { [self] creation in
            try create(creation.id, pluginID: creation.pluginID, title: creation.title, directory: creation.directory)
        }, locateCreation: { [self] in launches[$0] })
        await service.refresh()
        return service
    }

    func complete(_ message: AgentMessage, answer: String = "verified answer") async throws {
        let turn = UUID().uuidString
        let file = root.appendingPathComponent(turn).appendingPathExtension("jsonl")
        try (JSONEncoder().encode(["turn": turn, "final": answer]) + Data([10])).write(to: file)
        let peer = try #require(PluginIngressPeer.capture(peerPID: message.instance.processID, userID: 501) { pid in
            .init(processID: pid, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
        })
        for (kind, text) in [(PluginWorkflowEvent.Kind.submitted, message.prompt), (.stopCandidate, answer)] {
            try await interaction.receive(.init(
                pluginID: message.instance.pluginID,
                sessionID: message.instance.conversationID,
                tmuxPane: message.instance.paneID,
                workflow: .init(kind: kind, nativeTurnID: turn, transcriptPath: file.path, text: text)
            ), peer: peer)
        }
        for _ in 0..<200 {
            if try await interaction.store.message(message.id)?.status == .succeeded {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Native reply did not settle")
    }

    func cleanup() async throws {
        await interaction.shutdown()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    static func readOnly(root: URL, hostID: UUID, workflows: AgentWorkflowService) async throws -> AgentMessageService {
        let catalog = AgentRuntimeCatalog(hostID: hostID) { _ in try await workflows.snapshot(refreshInstances: true).instances.map(AgentWorkflowObservation.init) }
        let writer = AgentInputWriter(gate: .init(), inspect: { $0 }, submit: { _, _, _, _, _ in Issue.record("Unexpected write") })
        let service = AgentMessageService(
            store: .init(directory: root.appendingPathComponent("messages")),
            catalog: catalog,
            writer: writer,
            temporaryDirectory: root.appendingPathComponent("input"),
            inspect: { $0 },
            occupied: { _ in nil },
            provider: { _ in nil },
            onFailure: { Issue.record(Comment(rawValue: $0)) }
        )
        try await service.start()
        return service
    }
}
