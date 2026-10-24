import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowRequestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Fixture {
        let root: URL
        let store: AgentWorkflowStore
        let service: AgentWorkflowService
        let hostID: UUID
        let definition: AgentWorkflowDefinition
        let instances: [AgentWorkflowInstance]
    }

    private func fixture(count: Int = 1) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-request-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let observations = (0..<count).map { index in
            AgentWorkflowObservation(
                pluginID: "codex", processID: Int32(100 + index), processRuntimeID: "start-\(index)",
                workspacePane: .init(serverID: "server", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
                paneID: "%\(index)", conversationID: UUID().uuidString,
                displayName: "Agent \(index)", workingDirectory: "/work",
                capabilities: .init(maximumInputBytes: 256 * 1_024), readiness: .ready
            )
        }
        let service = AgentWorkflowService(store: store, scan: { _ in observations }, schedule: { _ in }, now: { now })
        let instances = try await service.refreshInstancesCatalog()
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instances[0].id, input: .init(text: "$skill\nDo the task"))
        let definition = try await service.save(.init(
            name: "Workflow", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id,
            initialInput: .init(text: "Initial task")
        ), expectedRevision: nil)
        return .init(root: root, store: store, service: service, hostID: hostID, definition: definition, instances: instances)
    }

    private func start(_ f: Fixture, id: UUID = UUID()) async throws -> AgentWorkflowRunState {
        try #require(try await f.service.handle(.init(.start(
            definitionID: f.definition.id, expectedRevision: f.definition.revision,
            requestID: id, authorizationExpiresAt: now.addingTimeInterval(3_600)
        ), expectedHostID: f.hostID)).run)
    }

    @Test
    func mutationsRequireObservedHostAndSupportedProtocolBeforeWriting() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.service.snapshot()
        for hostID in [nil, UUID()] {
            await #expect(throws: AgentWorkflowError.self) {
                try await f.service.handle(.init(.deleteDefinition(f.definition.id, expectedRevision: 1), expectedHostID: hostID))
            }
        }
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.handle(.init(.deleteDefinition(f.definition.id, expectedRevision: 1), expectedHostID: f.hostID, version: 2))
        }
        #expect(try await f.service.snapshot() == before)
    }

    @Test
    func operatorControlUsesRevisionAndLostStartReplyIsRetryable() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = try await start(f)
        #expect(try await start(f, id: state.summary.id) == state)
        let paused = try #require(try await f.service.handle(.init(.pause(state.summary.id, expectedRevision: state.summary.revision), expectedHostID: f.hostID)).run)
        #expect(paused.summary.status == .paused)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.handle(.init(.end(state.summary.id, expectedRevision: state.summary.revision), expectedHostID: f.hostID))
        }
        let ended = try #require(try await f.service.handle(.init(.end(state.summary.id, expectedRevision: paused.summary.revision), expectedHostID: f.hostID)).run)
        #expect(ended.summary.status == .ended)
        _ = try await f.service.handle(.init(.deleteRun(state.summary.id, expectedRevision: ended.summary.revision), expectedHostID: f.hostID))
        #expect(try await f.service.snapshot().runs.isEmpty)
    }

    @Test
    func oversizedConfigurationIsRejectedBeforeSave() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var edited = f.definition
        edited.initialInput.text = String(repeating: "x", count: AgentWorkflowWire.maximumDefinitionBytes)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.handle(.init(.save(edited, expectedRevision: 1), expectedHostID: f.hostID))
        }
        #expect(try await f.service.snapshot().definitions == [f.definition])
    }

    @Test
    func catalogPagesReturnEveryInstanceWithoutRepeating() async throws {
        let f = try await fixture(count: 85)
        defer { try? FileManager.default.removeItem(at: f.root) }
        var offset: Int? = 0
        var ids: [UUID] = []
        while let current = offset {
            let response = try await f.service.handle(.init(.catalog(offset: current)))
            let page = try #require(response.instances)
            #expect(page.items.count <= AgentWorkflowWire.maximumPageItems)
            ids += page.items.map(\.id)
            offset = page.nextOffset
        }
        #expect(ids == f.instances.map(\.id))
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.handle(.init(.catalog(offset: -1)))
        }
    }

    @Test
    func longResultsStayOutOfStateAndRoundTripThroughUTF8Pages() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = try await start(f)
        let runID = state.summary.id
        let prepared = try await f.store.update(runID: runID) {
            _ = try $0.prepareInvocation(nodeID: f.definition.entryNodeID, now: now)
        }
        let invocationID = try #require(prepared.invocations.first?.id)
        let body = "secret-output-marker\n" + String(repeating: "中🙂/\"\u{0000}\n", count: 30_000)
        try await f.store.update(runID: runID) {
            try $0.beginWriting(invocationID: invocationID, instance: f.instances[0], now: now)
            try $0.didWrite(invocationID: invocationID)
            try $0.accept(invocationID: invocationID, instance: f.instances[0], nativeTurnID: "turn", transcriptPath: "/private/native-log")
            try $0.succeed(.init(invocationID: invocationID, nativeTurnID: "turn", text: body, completedAt: now), instance: f.instances[0], now: now)
        }
        for operation in [ManageAgentWorkflows.Operation.runs(offset: 0), .run(runID), .invocations(runID: runID, offset: 0)] {
            let response = try await f.service.handle(.init(operation))
            let json = try String(decoding: JSONEncoder().encode(response), as: UTF8.self)
            #expect(!json.contains("secret-output-marker"))
            #expect(!json.contains("native-log"))
        }
        var restored = ""
        var offset: Int? = 0
        while let current = offset {
            let response = try await f.service.handle(.init(.text(runID: runID, invocationID: invocationID, part: .result, offset: current)))
            let page = try #require(response.text)
            #expect(page.totalBytes == body.utf8.count)
            #expect(try JSONEncoder().encode(response).count <= AgentWorkflowWire.maximumEncodedBytes)
            restored += page.text
            offset = page.nextOffset
        }
        #expect(restored == body)
    }

    @Test
    func inputIsReadableBeforeResultAndFrozenConfigurationSurvivesEdits() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = try await start(f)
        let prepared = try await f.store.update(runID: state.summary.id) {
            _ = try $0.prepareInvocation(nodeID: f.definition.entryNodeID, now: now)
        }
        let invocation = try #require(prepared.invocations.first)
        let input = try await f.service.handle(.init(.text(runID: state.summary.id, invocationID: invocation.id, part: .input, offset: 0)))
        #expect(input.text?.text == invocation.delivery.input.text)
        await #expect(throws: AgentWorkflowError.self) {
            try await f.service.handle(.init(.text(runID: state.summary.id, invocationID: invocation.id, part: .result, offset: 0)))
        }
        var changed = f.definition
        changed.initialInput.text = "Changed goal"
        _ = try await f.service.handle(.init(.save(changed, expectedRevision: 1), expectedHostID: f.hostID))
        #expect(try await f.service.handle(.init(.runDefinition(state.summary.id))).definition == f.definition)
    }
}
