import CtrlxNetworking
import Foundation

extension AgentWorkflowService {
    /// Called only by local operator UI or an authenticated paired Viewer. Agent
    /// sockets expose the separately authorized finish operation, not this API.
    func handle(_ request: ManageAgentWorkflows) async throws -> AgentWorkflowResponse {
        guard request.version == AgentWorkflowWire.version else {
            throw AgentWorkflowError("Update CtrlX to use this workflow protocol version.")
        }
        guard try JSONEncoder().encode(request).count <= AgentWorkflowWire.maximumEncodedBytes else {
            throw AgentWorkflowError("The workflow request is too large.")
        }
        let archive = try await snapshot()
        guard (request.expectedHostID == nil && !request.operation.isMutation) || request.expectedHostID == archive.hostID else {
            throw AgentWorkflowError("The Host identity changed. Reload workflows before making changes.")
        }
        var response = AgentWorkflowResponse(hostID: archive.hostID)
        switch request.operation {
        case let .catalog(offset):
            let instances = try await refreshInstancesCatalog()
            response.instances = try Self.page(instances, offset: offset)
        case let .definitions(offset):
            response.definitions = try Self.page(archive.definitions.map(AgentWorkflowDefinitionSummary.init), offset: offset)
        case let .definition(id):
            guard let definition = archive.definitions.first(where: { $0.id == id }) else {
                throw AgentWorkflowError("This workflow configuration no longer exists.")
            }
            response.definition = definition
        case let .save(definition, expectedRevision):
            response.definition = try await save(definition, expectedRevision: expectedRevision)
        case let .deleteDefinition(id, expectedRevision):
            try await deleteDefinition(id: id, expectedRevision: expectedRevision)
        case let .start(definitionID, expectedRevision, requestID, authorizationExpiresAt):
            let run = try await start(definitionID: definitionID, expectedRevision: expectedRevision, requestID: requestID, authorizationExpiresAt: authorizationExpiresAt)
            response.run = try AgentWorkflowRunState(run, currentInstances: await snapshot().instances)
        case let .runs(offset):
            response.runs = try Self.page(archive.runs.reversed().map(AgentWorkflowRunSummary.init), offset: offset)
        case let .run(id):
            response.run = try AgentWorkflowRunState(Self.run(id, in: archive), currentInstances: archive.instances)
        case let .runDefinition(id):
            response.definition = try Self.run(id, in: archive).definition
        case let .invocations(runID, offset):
            response.invocations = try Self.page(Self.run(runID, in: archive).invocations.map(AgentWorkflowInvocationSummary.init), offset: offset)
        case let .text(runID, invocationID, part, offset):
            let run = try Self.run(runID, in: archive)
            guard let invocation = run.invocations.first(where: { $0.id == invocationID }) else {
                throw AgentWorkflowError("This workflow invocation no longer exists.")
            }
            let text: String
            switch part {
            case .input: text = invocation.delivery.input.text
            case .result:
                guard let result = invocation.result else { throw AgentWorkflowError("The Agent has not produced a verified result yet.") }
                text = result.text
            }
            response.text = try Self.textPage(text, offset: offset)
        case let .pause(id, revision):
            response.run = try AgentWorkflowRunState(await pause(runID: id, expectedRevision: revision), currentInstances: archive.instances)
        case let .resume(id, revision, roundLimit):
            let run = try await resume(runID: id, expectedRevision: revision, roundLimit: roundLimit)
            response.run = try AgentWorkflowRunState(run, currentInstances: await snapshot().instances)
        case let .end(id, revision):
            response.run = try AgentWorkflowRunState(await end(runID: id, expectedRevision: revision), currentInstances: archive.instances)
        case let .deleteRun(id, revision):
            try await deleteRun(id: id, expectedRevision: revision)
        case let .attachments(ids):
            response.attachments = try await attachments(ids)
        case let .uploadAttachment(operation):
            let uploaded = try await uploadAttachment(operation)
            response.uploadedOffset = uploaded.offset
            response.attachments = uploaded.attachment.map { [$0] }
        case let .discardAttachments(ids):
            try await discardAttachments(ids)
        case let .linkConversion(sourceID, outputs):
            response.attachments = try await linkConversion(sourceID: sourceID, outputs: outputs)
        }
        guard try JSONEncoder().encode(response).count <= AgentWorkflowWire.maximumEncodedBytes else {
            throw AgentWorkflowError("The workflow response is too large. Read its input or result separately.")
        }
        return response
    }

    private static func run(_ id: UUID, in archive: AgentWorkflowArchive) throws -> AgentWorkflowRun {
        guard let run = archive.runs.first(where: { $0.id == id }) else {
            throw AgentWorkflowError("This workflow run no longer exists.")
        }
        return run
    }

    private static func page<Item>(_ items: [Item], offset: Int) throws -> AgentWorkflowPage<Item> {
        guard (0...items.count).contains(offset) else { throw AgentWorkflowError("The workflow list changed. Reload it.") }
        var selected: [Item] = []
        for item in items.dropFirst(offset).prefix(AgentWorkflowWire.maximumPageItems) {
            let proposed = selected + [item]
            guard try JSONEncoder().encode(proposed).count <= AgentWorkflowWire.maximumEncodedBytes / 2 else { break }
            selected = proposed
        }
        guard !selected.isEmpty || offset == items.count else { throw AgentWorkflowError("A workflow list entry is too large.") }
        let next = offset + selected.count
        return .init(items: selected, nextOffset: next < items.count ? next : nil)
    }

    private static func textPage(_ text: String, offset: Int) throws -> AgentWorkflowTextPage {
        let bytes = Array(text.utf8)
        guard (0...bytes.count).contains(offset), offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else {
            throw AgentWorkflowError("Invalid workflow text offset.")
        }
        var end = min(bytes.count, offset + AgentWorkflowWire.textPageBytes)
        while end < bytes.count, bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }
        guard let page = String(bytes: bytes[offset..<end], encoding: .utf8) else {
            throw AgentWorkflowError("The workflow text is not valid UTF-8.")
        }
        return .init(text: page, nextOffset: end < bytes.count ? end : nil, totalBytes: bytes.count)
    }
}
