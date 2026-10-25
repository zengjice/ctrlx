import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowBridgeTests {
    private struct Fixture {
        let root: URL
        let store: AgentWorkflowStore
        let instance: AgentWorkflowInstance
        let peer: PluginIngressPeer

        func event(version: Int = 1) -> PluginEvent {
            .init(pluginID: instance.pluginID, sessionID: instance.conversationID, tmuxPane: instance.paneID, workflowBridgeVersion: version)
        }

        func record(_ event: PluginEvent) async throws -> Bool {
            try await store.recordBridge(event, processID: instance.processID, runtimeID: instance.processRuntimeID, peer: peer)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-bridge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let instance = AgentWorkflowInstance(
            hostID: UUID(), pluginID: "codex", processID: 10, processRuntimeID: "501:10:100:0",
            workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: UUID().uuidString, displayName: "Developer", workingDirectory: root.path,
            capabilities: nil, readiness: .unavailable
        )
        let peer = try #require(PluginIngressPeer.capture(peerPID: 11, userID: 501) { pid in
            switch pid {
            case 11: .init(processID: 11, parentProcessID: 10, userID: 501, startSeconds: 101, startMicroseconds: 0)
            case 10: .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
            default: nil
            }
        })
        return .init(root: root, store: AgentWorkflowStore(fileURL: root.appendingPathComponent("state/ledger.json"), hostID: instance.hostID), instance: instance, peer: peer)
    }

    @Test
    func authenticBridgeCanBeRecordedBeforeCatalogAndSurvivesHostRestart() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try await f.store.bridgeIssue(for: f.instance) != nil)
        #expect(try await f.record(f.event()))
        #expect(try await f.store.bridgeIssue(for: f.instance) == nil)
        #expect(try await f.store.hasBridgeObservation(f.event(), peer: f.peer))
        let file = f.root.appendingPathComponent("state/ledger.json")
        let before = try Data(contentsOf: file)
        #expect(try await f.record(f.event()))
        #expect(try Data(contentsOf: file) == before)
        let restarted = AgentWorkflowStore(fileURL: file, hostID: f.instance.hostID)
        #expect(try await restarted.bridgeIssue(for: f.instance) == nil)
    }

    @Test
    func differentProcessConversationOrPluginCannotInheritEvidence() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try await f.record(f.event()))
        var conversation = f.instance
        conversation.conversationID = UUID().uuidString
        #expect(try await f.store.bridgeIssue(for: conversation) != nil)
        let observation = AgentWorkflowObservation(f.instance)
        var replaced = observation
        replaced.processRuntimeID = "501:10:200:0"
        #expect(try await f.store.bridgeIssue(for: replaced.instance(hostID: f.instance.hostID, id: f.instance.id)) != nil)
        replaced = observation
        replaced.pluginID = "claude-code"
        #expect(try await f.store.bridgeIssue(for: replaced.instance(hostID: f.instance.hostID, id: f.instance.id)) != nil)
        #expect(try await !f.store.recordBridge(f.event(), processID: 99, runtimeID: "501:99:100:0", peer: f.peer))
        #expect(try await !f.store.recordBridge(f.event(), processID: 10, runtimeID: "501:10:200:0", peer: f.peer))
        #expect(try await f.store.bridgeIssue(for: f.instance) == nil)
    }

    @Test(arguments: [0, 2])
    func olderOrUnknownBridgePausesAnActiveRun(version: Int) async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var observed = AgentWorkflowObservation(f.instance)
        observed.capabilities = .init(maximumInputBytes: 100_000)
        observed.readiness = .ready
        let instance = try #require(await f.store.reconcile([observed]).first)
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
        let definition = try await f.store.saveDefinition(.init(name: "Test", hostID: instance.hostID, nodes: [node], edges: [], entryNodeID: node.id), expectedRevision: nil)
        _ = try await f.store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(60))
        #expect(try await f.record(f.event()))
        #expect(try await f.record(f.event(version: version)))
        #expect(try await f.store.bridgeIssue(for: instance) != nil)
        #expect(try await f.store.snapshot().runs[0].status == .paused)
        #expect(try await f.record(f.event()))
        #expect(try await f.store.bridgeIssue(for: instance) == nil)
        #expect(try await f.store.snapshot().runs[0].status == .paused)
    }

    @Test
    func failedPersistenceDoesNotExposeBridgeReadiness() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.store.snapshot()
        try Data("blocked".utf8).write(to: f.root.appendingPathComponent("state"))
        await #expect(throws: (any Error).self) { try await f.record(f.event()) }
        #expect(try await f.store.bridgeIssue(for: f.instance) != nil)
    }
}
