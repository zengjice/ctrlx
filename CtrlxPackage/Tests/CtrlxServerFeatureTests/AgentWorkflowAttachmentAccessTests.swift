import CryptoKit
import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

struct AgentWorkflowAttachmentAccessTests {
    private struct Fixture: Sendable {
        let root: URL
        let store: AgentWorkflowStore
        let observation: AgentWorkflowObservation
        let instance: AgentWorkflowInstance
        let definition: AgentWorkflowDefinition
        let attachment: AgentWorkflowAttachment
        let unrelated: AgentWorkflowAttachment
        let peer: PluginIngressPeer

        var file: URL {
            root.appendingPathComponent("attachments/\(attachment.id.uuidString)/content.txt")
        }

        func start(accepted: Bool = true) async throws -> AgentWorkflowInvocation {
            let run = try await store.start(definitionID: definition.id, expectedRevision: definition.revision, requestID: UUID(), now: .now, authorizationExpiresAt: .now.addingTimeInterval(3_600))
            let updated = try await store.update(runID: run.id) {
                let task = try $0.prepareInvocation(nodeID: definition.entryNodeID, now: .now)
                if accepted {
                    try $0.beginWriting(invocationID: task.id, instance: instance, now: .now)
                    try $0.accept(invocationID: task.id, instance: instance, nativeTurnID: "turn-1")
                }
            }
            return try #require(updated.invocations.first)
        }

        func request(_ task: AgentWorkflowInvocation) -> JSONRPCRequest {
            .init(id: "attachments", method: "workflow.attachments", params: ["invocationId": .string(task.id.uuidString)])
        }
    }

    private func fixture(mediaType: String = "text/plain", contents: Data = Data("Read this complete task.\n第二行".utf8)) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-workflow-access-\(UUID())")
        let hostID = UUID()
        let store = AgentWorkflowStore(fileURL: root.appendingPathComponent("ledger.json"), hostID: hostID)
        func upload(_ data: Data, name: String) async throws -> AgentWorkflowAttachment {
            let id = UUID()
            _ = try await store.uploadAttachment(.begin(id: id, name: name, mediaType: mediaType, size: data.count))
            for offset in stride(from: 0, to: data.count, by: AgentWorkflowWire.attachmentChunkBytes) {
                let end = min(data.count, offset + AgentWorkflowWire.attachmentChunkBytes)
                _ = try await store.uploadAttachment(.append(id: id, offset: offset, data: data.subdata(in: offset..<end)))
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return try #require(await store.uploadAttachment(.finish(id: id, sha256: hash)).attachment)
        }
        let attachment = try await upload(contents, name: "Task.txt")
        let unrelated = try await upload(Data("Private unrelated import".utf8), name: "Unrelated.txt")
        await store.shutdownAttachmentUploads()
        let observation = AgentWorkflowObservation(
            pluginID: "codex", processID: 10, processRuntimeID: "501:10:100:0",
            workspacePane: .init(serverID: "1:100", sessionID: UUID(), windowID: UUID(), paneID: UUID()),
            paneID: "%1", conversationID: "conversation", displayName: "Developer", workingDirectory: root.path,
            capabilities: .init(maximumInputBytes: 100_000, mediaTypes: [mediaType]), readiness: .ready
        )
        let instance = try #require(await store.reconcile([observation]).first)
        let node = AgentWorkflowNode(name: "Developer", agentInstanceID: instance.id)
        let definition = try await store.saveDefinition(.init(name: "Task", hostID: hostID, nodes: [node], edges: [], entryNodeID: node.id, initialInput: .init(text: "Read the attachment", attachmentIDs: [attachment.id]), loop: .init(finalNodeID: node.id)), expectedRevision: nil)
        let peer = try #require(PluginIngressPeer.capture(peerPID: 11, userID: 501) { pid in
            switch pid {
            case 11: .init(processID: 11, parentProcessID: 10, userID: 501, startSeconds: 101, startMicroseconds: 0)
            case 10: .init(processID: 10, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
            default: nil
            }
        })
        return .init(root: root, store: store, observation: observation, instance: instance, definition: definition, attachment: attachment, unrelated: unrelated, peer: peer)
    }

    @Test
    func acceptedInvocationOnlyReceivesItsOwnVerifiedFiles() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.start()
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 })
        let response = await service.handle(f.request(task), peer: f.peer)
        #expect(response.ok)
        guard
            case let .array(items) = response.result?["attachments"],
            case let .object(file) = try #require(items.first) else {
            Issue.record("Missing attachment metadata")
            return
        }
        #expect(items.count == 1)
        #expect(file["id"] == .string(f.attachment.id.uuidString))
        #expect(file["path"] == .string(f.file.path))
        #expect(file["sha256"] == .string(f.attachment.sha256))
        #expect(!task.delivery.input.text.contains(f.file.path))
        #expect(task.delivery.input.text.contains("ctrlx workflow attachments --invocation \(task.id.uuidString) --json"))
    }

    @Test(arguments: [false, true])
    func pauseRetainsAcceptedTaskFilesWithoutAllowingAnotherSubmission(accepted: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.start(accepted: accepted)
        _ = try await f.store.update(runID: task.delivery.runID) { $0.pause(reason: "Permission requires a human response") }
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 })
        let response = await service.handle(f.request(task), peer: f.peer)
        if accepted {
            try #require(response.ok)
            guard case let .array(files) = response.result?["attachments"] else {
                Issue.record("The paused task lost its files")
                return
            }
            #expect(files.count == 1)
            let completed = try await f.store.update(runID: task.delivery.runID) {
                _ = try $0.succeed(.init(invocationID: task.id, nativeTurnID: "turn-1", text: "Read the input", completedAt: .now), instance: f.instance, now: .now)
            }
            #expect(completed.status == .paused)
            #expect(completed.round == 1)
            #expect(try AgentWorkflowExecution(validating: completed).readyNodeIDs.isEmpty)
            #expect(await service.handle(f.request(task), peer: f.peer).error?.code == "workflow_denied")
        } else {
            #expect(response.error?.code == "workflow_denied")
            await #expect(throws: AgentWorkflowError.self) {
                try await f.store.invocationAttachments(task, instance: f.instance, status: .pending, now: .now)
            }
        }
    }

    @Test(arguments: ["missingPeer", "otherPeer", "changedConversation", "expired", "ended", "pending", "oldRound"], [false, true])
    func unauthorizedReadsNeverRevealPaths(_ condition: String, paused: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.start(accepted: condition != "pending")
        let service = AgentWorkflowAgentService(store: f.store, inspect: { instance in
            var live = instance
            if condition == "changedConversation" {
                live.conversationID = "replacement"
            }
            return live
        }, now: { condition == "expired" ? Date.distantFuture : .now })
        if condition == "ended" || condition == "oldRound" {
            _ = try await f.store.update(runID: task.delivery.runID) {
                if condition == "ended" {
                    $0.end()
                }
                if condition == "oldRound" {
                    _ = try $0.succeed(.init(invocationID: task.id, nativeTurnID: "turn-1", text: "Next round", completedAt: .now), instance: f.instance, now: .now)
                }
            }
        }
        if paused {
            _ = try await f.store.update(runID: task.delivery.runID) { $0.pause(reason: "Human takeover") }
        }
        var peer: PluginIngressPeer? = f.peer
        if condition == "missingPeer" {
            peer = nil
        }
        if condition == "otherPeer" {
            peer = PluginIngressPeer.capture(peerPID: 12, userID: 501) {
                .init(processID: $0, parentProcessID: 1, userID: 501, startSeconds: 100, startMicroseconds: 0)
            }
        }
        let response = await service.handle(f.request(task), peer: peer)
        #expect(response.error?.code == "workflow_denied")
        #expect(response.result == nil)
    }

    @Test
    func revocationDuringVerificationIsCheckedBeforeReturning() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.start()
        actor Inspector {
            var calls = 0
            func inspect(_ instance: AgentWorkflowInstance, fixture: Fixture, task: AgentWorkflowInvocation) async throws -> AgentWorkflowInstance {
                calls += 1
                if calls == 2 {
                    _ = try await fixture.store.update(runID: task.delivery.runID) { $0.end() }
                }
                return instance
            }
        }
        let inspector = Inspector()
        let service = AgentWorkflowAgentService(store: f.store, inspect: { try await inspector.inspect($0, fixture: f, task: task) })
        #expect(await service.handle(f.request(task), peer: f.peer).error?.code == "workflow_denied")
    }

    @Test(arguments: ["changed", "symlink", "invalidUTF8", "oversize", "rawAudio"])
    func invalidAttachmentsBlockStartBeforeScheduling(_ condition: String) async throws {
        let data = switch condition {
        case "invalidUTF8": Data([0xFF, 0xFE])
        case "oversize": Data(repeating: 0x61, count: 2 * 1_024 * 1_024 + 1)
        default: Data("Original task".utf8)
        }
        let f = try await fixture(mediaType: condition == "rawAudio" ? "audio/wav" : "text/plain", contents: data)
        defer { try? FileManager.default.removeItem(at: f.root) }
        if condition == "changed" {
            try Data("Tampered task".utf8).write(to: f.file)
        }
        if condition == "symlink" {
            let target = f.root.appendingPathComponent("outside.txt")
            try data.write(to: target)
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: target)
        }
        let service = AgentWorkflowService(store: f.store, scan: { _ in [f.observation] }, schedule: { _ in Issue.record("Invalid media was scheduled") })
        await #expect(throws: AgentWorkflowError.self) {
            try await service.start(definitionID: f.definition.id, expectedRevision: f.definition.revision, requestID: UUID(), authorizationExpiresAt: .now.addingTimeInterval(3_600))
        }
        #expect(try await f.store.snapshot().runs.isEmpty)
    }

    @Test
    func PNGIsValidatedAsAnImageRatherThanByFilename() async throws {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV1cAAAAASUVORK5CYII="))
        let f = try await fixture(mediaType: "image/png", contents: bytes)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.start()
        let service = AgentWorkflowAgentService(store: f.store, inspect: { $0 })
        #expect(await service.handle(f.request(task), peer: f.peer).ok)
        let wrongFormat = try await fixture(mediaType: "image/png", contents: Data("not an image".utf8))
        defer { try? FileManager.default.removeItem(at: wrongFormat.root) }
        let wrongTask = try await wrongFormat.start()
        let denied = await AgentWorkflowAgentService(store: wrongFormat.store, inspect: { $0 }).handle(wrongFormat.request(wrongTask), peer: wrongFormat.peer)
        #expect(denied.error?.code == "workflow_denied")
    }

    @Test(arguments: [false, true])
    @MainActor
    func terminalReceivesAuthorizedLookupWithoutRewritingItsText(corrupted: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let task = try await f.start(accepted: false)
        if corrupted {
            try Data("Changed after preparing the run".utf8).write(to: f.file)
        }
        let temporary = f.root.appendingPathComponent("input")
        var submitted: String?
        let transport = AgentWorkflowTerminalTransport(store: f.store, gate: .init { _ in }, temporaryDirectory: temporary, inspect: { $0 }, submit: { _, file, validate in
            try validate { }
            submitted = try String(contentsOf: file, encoding: .utf8)
        }, onFailure: { Issue.record("\($0)") }).transport
        if corrupted {
            await #expect(throws: AgentWorkflowError.self) { try await transport.prepare(task, f.instance) }
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            #expect(submitted == nil)
        } else {
            try await transport.prepare(task, f.instance)
            _ = try await f.store.update(runID: task.delivery.runID) {
                try $0.beginWriting(invocationID: task.id, instance: f.instance, now: .now)
            }
            try await transport.write(task, f.instance)
            #expect(submitted == task.delivery.input.text)
            #expect(submitted?.contains(f.file.path) == false)
            await transport.discard(task.id)
            #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        }
    }
}
