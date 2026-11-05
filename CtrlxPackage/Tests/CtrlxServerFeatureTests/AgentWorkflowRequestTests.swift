import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowRequestTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    final private class WriteBoundary {
        var entered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

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
    func terminalControlIsScopedToStablePaneAndUsesTheCurrentRun() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pane = f.instances[0].workspacePane
        #expect(try await f.service.handle(.init(.terminal(pane))).run == nil)
        let run = try await start(f)
        let state = try #require(await f.service.handle(.init(.terminal(pane))).run)
        #expect(state.summary.id == run.summary.id)
        var other = pane
        other.paneID = UUID()
        #expect(try await f.service.handle(.init(.terminal(other))).run == nil)
        let paused = try #require(await f.service.handle(.init(.pause(run.summary.id, expectedRevision: state.summary.revision), expectedHostID: f.hostID)).run)
        #expect(paused.summary.status == .paused)
        let current = try #require(await f.service.handle(.init(.terminal(pane))).run)
        let resumed = try #require(await f.service.handle(.init(.resume(run.summary.id, expectedRevision: current.summary.revision, roundLimit: nil), expectedHostID: f.hostID)).run)
        #expect(resumed.summary.status == .running)
        _ = try await f.service.handle(.init(.end(run.summary.id, expectedRevision: resumed.summary.revision), expectedHostID: f.hostID))
        #expect(try await f.service.handle(.init(.terminal(pane))).run == nil)
    }

    @Test(arguments: [false, true])
    func terminalControlFollowsTheReplacementAgentWithoutChangingItsOldRun(reusesPID: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = f.instances[0]
        let oldRun = try await start(f)
        _ = try await f.store.reconcile([])
        #expect(try await f.service.handle(.init(.terminal(original.workspacePane))).run == nil)

        var observation = AgentWorkflowObservation(original)
        if !reusesPID {
            observation.processID += 1
        }
        observation.processRuntimeID += ":replacement"
        observation.conversationID = UUID().uuidString
        let replacement = observation
        let service = AgentWorkflowService(store: f.store, scan: { _ in [replacement] }, schedule: { _ in }, now: { now })
        let live = try #require(await service.refreshInstancesCatalog().first)
        #expect(live.id != original.id && live.workspacePane == original.workspacePane)
        let node = AgentWorkflowNode(name: "Replacement", agentInstanceID: live.id)
        let definition = try await service.save(.init(name: "New workflow", hostID: f.hostID, nodes: [node], edges: [], entryNodeID: node.id), expectedRevision: nil)
        let newRun = try await service.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), authorizationExpiresAt: now.addingTimeInterval(3_600))
        let oldState = try #require(await f.store.snapshot().runs.first { $0.id == oldRun.summary.id })
        #expect(oldState.status == .paused)

        let current = try #require(await service.handle(.init(.terminal(original.workspacePane))).run)
        #expect(current.summary.id == newRun.id && current.summary.status == .running)
        let paused = try #require(await service.handle(.init(.pause(current.summary.id, expectedRevision: current.summary.revision), expectedHostID: f.hostID)).run)
        #expect(paused.summary.id == newRun.id && paused.summary.status == .paused)
        let manual = try #require(await service.handle(.init(.terminal(original.workspacePane))).run)
        #expect(manual.summary.id == newRun.id)
        let resumed = try #require(await service.handle(.init(.resume(manual.summary.id, expectedRevision: manual.summary.revision, roundLimit: nil), expectedHostID: f.hostID)).run)
        #expect(resumed.summary.id == newRun.id && resumed.summary.status == .running)
        _ = try await service.handle(.init(.end(newRun.id, expectedRevision: resumed.summary.revision), expectedHostID: f.hostID))
        #expect(try await service.handle(.init(.terminal(original.workspacePane))).run == nil)
        #expect(try await f.store.snapshot().runs.first { $0.id == oldRun.summary.id } == oldState)
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
        for version in [1, 2] {
            await #expect(throws: AgentWorkflowError.self) {
                try await f.service.handle(.init(.deleteDefinition(f.definition.id, expectedRevision: 1), expectedHostID: f.hostID, version: version))
            }
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
    func removedArtifactAPIIsNeitherAdvertisedNorHandled() async throws {
        let router = LiveAPIRequestRouter()
        let capabilities = await router.handleRequest(.init(id: "capabilities", method: "system.capabilities", params: [:]))
        let value = try #require(capabilities.result?["methods"])
        guard case let .array(methods) = value else { Issue.record("Missing capability methods")
            return
        }
        #expect(!methods.contains(.string("workflow.artifact")))
        let store = AgentWorkflowStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("removed-artifact-\(UUID()).json"), hostID: UUID())
        let service = AgentWorkflowAgentService(store: store, inspect: { $0 })
        let response = await service.handle(.init(id: "removed", method: "workflow.artifact", params: [:]), peer: nil)
        #expect(response.error?.code == "method_not_found")
    }

    @MainActor
    @Test
    func terminalsAllowInputWhileRunningPausedAndResumed() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let running = try await start(f)
        let before = try await f.store.snapshot()
        let writes = LockIsolated(0)
        try await withDependencies {
            $0[ProcessRunner.self].run = { _, _, _, _ in
                writes.withValue { $0 += 1 }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            let gate = AgentWorkflowInputGate()
            let tmux = TmuxService(tmuxPath: "/unused")
            tmux.workflowInputGate = gate
            let control = TmuxControlClientManager(tmuxPath: "/must/not/run")
            control.workflowInputGate = gate
            let claim = gate.claim(paneID: "%0")
            for _ in 0..<4 {
                try await tmux.sendKeys("%0", keys: "a", literal: true)
            }
            // A disconnected pipe returns false for the ordinary fallback,
            // without denying input based on the workflow state.
            #expect(try await !control.sendKeystrokesIfConnected(paneId: "%0", sessionName: "missing", keys: [.enter]))
            try await tmux.sendRawBytes("%0", data: Data("\u{1b}[<0;10;20M".utf8))
            #expect(writes.value == 5)
            #expect(throws: AgentWorkflowError.self) { try gate.validate(claim) }
            let beforeScroll = gate.claim(paneID: "%0")
            try await tmux.sendRawBytes("%0", data: Data("\u{1b}[<64;10;20M".utf8))
            #expect(writes.value == 6)
            try gate.validate(beforeScroll)
            #expect(try await f.store.snapshot() == before)

            let paused = try await f.service.pause(runID: running.summary.id, expectedRevision: running.summary.revision)
            try await tmux.sendKeys("%0", keys: "a", literal: true)
            #expect(try await f.store.snapshot().runs[0].status == .paused)
            let resumed = try await f.service.resume(runID: paused.id, expectedRevision: paused.revision)
            try await tmux.sendKeys("%0", keys: "Enter")
            #expect(try await f.store.snapshot().runs[0].status == .running)
            _ = try await f.service.end(runID: resumed.id, expectedRevision: resumed.revision)
            try await tmux.sendKeys("%0", keys: "a", literal: true)
            #expect(writes.value == 9)
        }
    }

    @MainActor
    @Test(arguments: [false, true])
    func continuingDoesNotDiscardQueuedHumanInput(pauseAgain: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let running = try await start(f)
        let paused = try await f.service.pause(runID: running.summary.id, expectedRevision: running.summary.revision)
        let boundary = WriteBoundary()
        let writes = LockIsolated(0)
        try await withDependencies {
            $0[ProcessRunner.self].run = { _, _, _, _ in
                await boundary.wait()
                writes.withValue { $0 += 1 }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/must/not/run")
            tmux.workflowInputGate = AgentWorkflowInputGate()
            let pending = Task { try await tmux.sendKeys("%0", keys: "C-c") }
            defer { boundary.release()
                pending.cancel()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !boundary.entered, ContinuousClock.now < deadline {
                await Task.yield()
            }
            try #require(boundary.entered)
            let resumed = try await f.service.resume(runID: paused.id, expectedRevision: paused.revision)
            if pauseAgain {
                _ = try await f.service.pause(runID: resumed.id, expectedRevision: resumed.revision)
            }
            boundary.release()
            try await pending.value
            #expect(writes.value == 1)
            #expect(try await f.store.snapshot().runs[0].status == (pauseAgain ? .paused : .running))
        }
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
