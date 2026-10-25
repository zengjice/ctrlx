import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowTerminalTransportTests {
    private struct Fixture {
        let root: URL
        let store: AgentWorkflowStore
        let instance: AgentWorkflowInstance
        let invocation: AgentWorkflowInvocation
    }

    private func fixture(text: String = "Initial task", attachments: [UUID] = []) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-input-test-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        let instances = try await store.reconcile([.init(
            pluginID: "codex", processID: 42, processRuntimeID: "42:1:0",
            workspacePane: .init(serverID: "12:34", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "test", displayName: "Agent", workingDirectory: root.path,
            capabilities: .init(maximumInputBytes: 100_000), readiness: .ready
        )])
        let instance = try #require(instances.first)
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
        let definition = try await store.saveDefinition(.init(name: "Test", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: text, attachmentIDs: attachments)), expectedRevision: nil)
        let run = try await store.start(definitionID: definition.id, expectedRevision: 1, requestID: UUID(), now: Date(), authorizationExpiresAt: Date().addingTimeInterval(3_600))
        let updated = try await store.update(runID: run.id) { _ = try $0.prepareInvocation(nodeID: node.id, now: Date()) }
        return try Fixture(root: root, store: store, instance: instance, invocation: #require(updated.invocations.first))
    }

    private func markWriting(_ fixture: Fixture) async throws {
        try await fixture.store.update(runID: fixture.invocation.delivery.runID) {
            try $0.beginWriting(invocationID: fixture.invocation.id, instance: fixture.instance, now: Date())
        }
    }

    @Test
    func nativeInputIsPreparedPrivatelySubmittedAndRemoved() async throws {
        let fixture = try await fixture(text: "$review-changes\n审查当前修改")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var sent = false
        let inputRoot = fixture.root.appendingPathComponent("input")
        let delivery = AgentWorkflowTerminalTransport(store: fixture.store, gate: .init { _ in }, temporaryDirectory: inputRoot, inspect: { $0 }, submit: { _, file, validate in
            try validate { }
            #expect(try String(contentsOf: file, encoding: .utf8) == fixture.invocation.delivery.input.text)
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
            sent = true
        }, onFailure: { Issue.record("\($0)") })
        let transport = delivery.transport
        try await transport.prepare(fixture.invocation, fixture.instance)
        try await markWriting(fixture)
        try await transport.write(fixture.invocation, fixture.instance)
        await transport.discard(fixture.invocation.id)
        #expect(sent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: inputRoot.path).isEmpty)
    }

    @Test
    func humanInputDuringFinalCaptureStopsSubmission() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = AgentWorkflowInputGate { _ in }
        let claim = gate.claim(paneID: fixture.instance.paneID)
        var human: Task<Void, any Error>?
        let delivery = AgentWorkflowTerminalTransport(store: fixture.store, gate: gate, temporaryDirectory: fixture.root.appendingPathComponent("input"), inspect: { $0 }, submit: { _, _, validate in
            human = Task { try await gate.human(paneID: fixture.instance.paneID) { } }
            while (try? gate.validate(claim)) != nil {
                await Task.yield()
            }
            try validate { }
            Issue.record("Input reached an Agent after human takeover")
        }, onFailure: { Issue.record("\($0)") })
        let transport = delivery.transport
        try await transport.prepare(fixture.invocation, fixture.instance)
        try await markWriting(fixture)
        await #expect(throws: (any Error).self) { try await transport.write(fixture.invocation, fixture.instance) }
        try await human?.value
        await transport.discard(fixture.invocation.id)
    }

    @Test
    func pauseOrDraftBeforeWriteLeavesInputUntouched() async throws {
        for pause in [false, true] {
            let fixture = try await fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let delivery = AgentWorkflowTerminalTransport(store: fixture.store, gate: .init { _ in }, temporaryDirectory: fixture.root.appendingPathComponent("input"), inspect: {
                var live = $0
                if !pause {
                    live.readiness = .draft
                }
                return live
            }, submit: { _, _, _ in Issue.record("Unexpected submission") }, onFailure: { Issue.record("\($0)") })
            let transport = delivery.transport
            try await transport.prepare(fixture.invocation, fixture.instance)
            try await markWriting(fixture)
            if pause {
                try await fixture.store.update(runID: fixture.invocation.delivery.runID) { $0.pause(reason: "Paused") }
            }
            await #expect(throws: (any Error).self) { try await transport.write(fixture.invocation, fixture.instance) }
            await transport.discard(fixture.invocation.id)
        }
    }

    @Test(arguments: ["pause", "end", "pause-resume"])
    func controlChangeDuringFinalCapturePreventsDispatch(action: String) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let delivery = AgentWorkflowTerminalTransport(
            store: fixture.store, gate: .init { _ in }, temporaryDirectory: fixture.root.appendingPathComponent("input"),
            inspect: { $0 }, submit: { _, _, validate in
                // The transport passed its asynchronous state check. The final
                // terminal capture now suspends while the operator acts.
                try await fixture.store.update(runID: fixture.invocation.delivery.runID) {
                    if action == "end" {
                        $0.end()
                    } else {
                        $0.pause(reason: "Paused")
                    }
                }
                if action == "pause-resume" {
                    try await fixture.store.update(runID: fixture.invocation.delivery.runID) {
                        try $0.resume(instances: [fixture.instance], now: Date())
                    }
                }
                try validate { }
                Issue.record("Input was dispatched after a completed control change")
            }, onFailure: { Issue.record("\($0)") }
        )
        let transport = delivery.transport
        try await transport.prepare(fixture.invocation, fixture.instance)
        try await markWriting(fixture)
        await #expect(throws: AgentWorkflowInputNotWritten.self) { try await transport.write(fixture.invocation, fixture.instance) }
        await transport.discard(fixture.invocation.id)
    }

    @Test
    func finalAuthorizationExpiresAndCanOnlyBeClaimedOnce() throws {
        let expired = AgentWorkflowWriteAuthorization(expiresAt: .distantPast)
        #expect(throws: AgentWorkflowError.self) { try expired.perform { } }
        let live = AgentWorkflowWriteAuthorization(expiresAt: .distantFuture)
        try live.perform { }
        #expect(throws: AgentWorkflowError.self) { try live.perform { } }
    }

    @Test(arguments: [false, true])
    func finalAuthorizationGuardsRealProcessLaunch(revoked: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-launch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("launched")
        let authorization = AgentWorkflowWriteAuthorization(expiresAt: .distantFuture)
        try await withDependencies {
            $0[LoginShellPath.self] = .init(resolve: { "/usr/bin:/bin" })
            $0.continuousClock = ContinuousClock()
        } operation: {
            let run = {
                try await ProcessRunner.liveValue.runWithLaunch("/usr/bin/touch", [marker.path], nil, 5) { launch in
                    // Executed after ProcessRunner setup and the actor hop,
                    // immediately around the actual Foundation Process.run.
                    if revoked {
                        authorization.revoke()
                    }
                    try authorization.perform(launch)
                }
            }
            if revoked {
                await #expect(throws: AgentWorkflowError.self) { try await run() }
            } else {
                let result = try await run()
                #expect(result.isSuccess)
            }
            #expect(FileManager.default.fileExists(atPath: marker.path) == !revoked)
        }
    }

    @Test
    func terminalControlCharactersAreNotPasted() async throws {
        let fixture = try await fixture(text: "text\u{1b}[201~\rcommand")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let delivery = AgentWorkflowTerminalTransport(store: fixture.store, gate: .init { _ in }, temporaryDirectory: fixture.root.appendingPathComponent("input"), inspect: { $0 }, submit: { _, _, _ in Issue.record("Unexpected submission") }, onFailure: { Issue.record("\($0)") })
        await #expect(throws: (any Error).self) { try await delivery.transport.prepare(fixture.invocation, fixture.instance) }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("input").path))
    }
}
