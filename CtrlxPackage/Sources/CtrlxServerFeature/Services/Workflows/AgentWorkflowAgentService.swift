import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// The public invocation ID only selects a task. Authority comes from the
/// socket peer's verified process ancestry and the run's frozen node grant.
actor AgentWorkflowAgentService {
    private let store: AgentWorkflowStore
    private let inspect: @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let now: @Sendable () -> Date
    private let attachmentReader = AgentWorkflowAttachmentReader()

    init(
        store: AgentWorkflowStore,
        inspect: @escaping @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.inspect = inspect
        self.now = now
    }

    func handle(_ request: JSONRPCRequest, peer: PluginIngressPeer?) async -> JSONRPCResponse {
        if request.method == "workflow.artifact" {
            return await artifact(request, peer: peer)
        }
        if request.method == "workflow.attachments" {
            return await attachments(request, peer: peer)
        }
        guard request.method == "workflow.finish" else {
            return .methodNotFound(id: request.id, request.method)
        }
        guard
            Set(request.params.keys) == ["invocationId", "reason"],
            let rawID = request.params["invocationId"]?.stringValue,
            let invocationID = UUID(uuidString: rawID),
            let reason = request.params["reason"]?.stringValue,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            reason.utf8.count <= 8_192 else {
            return .invalidParams(id: request.id, "Expected invocationId and a nonempty reason of at most 8192 UTF-8 bytes.")
        }
        guard let peer else {
            return denied(request.id, "Cannot verify the workflow command's caller.")
        }
        do {
            let archive = try await store.snapshot()
            guard
                let run = archive.runs.first(where: { $0.invocations.contains { $0.id == invocationID } }),
                let invocation = run.invocations.first(where: { $0.id == invocationID }),
                let instance = run.instances.first(where: { $0.id == invocation.delivery.toAgentID }),
                peer.contains(processID: instance.processID, runtimeID: instance.processRuntimeID) else {
                return denied(request.id, "This caller does not own the workflow invocation.")
            }
            let live = try await inspect(instance)
            guard live.matchesBinding(instance) else {
                return denied(request.id, "The Agent process or conversation changed.")
            }
            let timestamp = now()
            let updated = try await store.update(runID: run.id) {
                try $0.requestFinish(invocationID: invocationID, instance: live, reason: reason, now: timestamp)
            }
            return JSONRPCResponse(id: request.id, result: [
                "runId": .string(updated.id.uuidString),
                "invocationId": .string(invocationID.uuidString),
                "status": .string(updated.status.rawValue),
                "message": .string(updated.status == .paused
                    ? "Finish request saved. Provide your final answer; the workflow remains paused until an operator continues it."
                    : "Finish request saved. Provide your final answer; the Host will verify completion before closing the workflow."),
            ])
        } catch let error as AgentWorkflowError {
            return denied(request.id, error.localizedDescription)
        } catch {
            return .internalError(id: request.id, "Could not save the workflow finish request: \(error.localizedDescription)")
        }
    }

    private func denied(_ id: String, _ message: String) -> JSONRPCResponse {
        .init(id: id, error: .init(code: "workflow_denied", message: message))
    }

    private func artifact(_ request: JSONRPCRequest, peer: PluginIngressPeer?) async -> JSONRPCResponse {
        let upload: AgentWorkflowArtifactRequest
        do { upload = try AgentWorkflowArtifactRequest(request.params) }
        catch { return .invalidParams(id: request.id, error.localizedDescription) }
        guard let peer else { return denied(request.id, "Cannot verify the workflow command's caller.") }
        do {
            let archive = try await store.snapshot()
            guard
                let run = archive.runs.first(where: { $0.invocations.contains { $0.id == upload.invocationID } }),
                let invocation = run.invocations.first(where: { $0.id == upload.invocationID }),
                let instance = run.instances.first(where: { $0.id == invocation.delivery.toAgentID }),
                peer.contains(processID: instance.processID, runtimeID: instance.processRuntimeID) else {
                return denied(request.id, "This caller does not own the workflow invocation.")
            }
            let context = AgentWorkflowStore.ArtifactUpload(
                owner: .init(runID: run.id, invocationID: invocation.id, instanceID: instance.id),
                instance: instance,
                verifyInstance: { [inspect, now] in
                    let live = try await inspect(instance)
                    guard live.matchesBinding(instance) else {
                        throw AgentWorkflowError("The Agent process or conversation changed.")
                    }
                    return now()
                }
            )
            let receipt = try await store.uploadAttachment(upload.operation, artifact: context)
            var result: [String: JSONValue] = [
                "invocationId": .string(invocation.id.uuidString),
                "uploadId": .string(upload.operation.id.uuidString),
                "offset": .int(receipt.offset),
            ]
            if let attachment = receipt.attachment {
                result["artifact"] = .object([
                    "id": .string(attachment.id.uuidString), "name": .string(attachment.name),
                    "mediaType": .string(attachment.mediaType), "size": .int(Int(attachment.byteCount)),
                    "sha256": .string(attachment.sha256),
                ])
            }
            return .init(id: request.id, result: result)
        } catch let error as AgentWorkflowError {
            return denied(request.id, error.localizedDescription)
        } catch {
            return .internalError(id: request.id, "Could not share the workflow artifact: \(error.localizedDescription)")
        }
    }

    private func attachments(_ request: JSONRPCRequest, peer: PluginIngressPeer?) async -> JSONRPCResponse {
        guard
            Set(request.params.keys) == ["invocationId"],
            let rawID = request.params["invocationId"]?.stringValue,
            let invocationID = UUID(uuidString: rawID) else {
            return .invalidParams(id: request.id, "Expected the invocationId supplied with this task.")
        }
        guard let peer else { return denied(request.id, "Cannot verify the workflow command's caller.") }
        do {
            let archive = try await store.snapshot()
            guard
                let run = archive.runs.first(where: { $0.invocations.contains { $0.id == invocationID } }),
                let invocation = run.invocations.first(where: { $0.id == invocationID }),
                let instance = run.instances.first(where: { $0.id == invocation.delivery.toAgentID }),
                peer.contains(processID: instance.processID, runtimeID: instance.processRuntimeID) else {
                return denied(request.id, "This caller does not own the workflow invocation.")
            }
            let live = try await inspect(instance)
            let files = try await store.invocationAttachments(invocation, instance: live, status: .running, now: now())
            try await attachmentReader.validate(files)
            let current = try await inspect(instance)
            let authorized = try await store.invocationAttachments(invocation, instance: current, status: .running, now: now())
            guard authorized == files else { throw AgentWorkflowError("The authorized attachments changed.") }
            return JSONRPCResponse(id: request.id, result: [
                "invocationId": .string(invocationID.uuidString),
                "attachments": .array(files.map { file in
                    var details: [String: JSONValue] = [
                        "id": .string(file.attachment.id.uuidString),
                        "name": .string(file.attachment.name),
                        "mediaType": .string(file.attachment.mediaType),
                        "sha256": .string(file.attachment.sha256),
                        "path": .string(file.url.path),
                        "readWith": .string(file.attachment.mediaType.hasPrefix("image/") ? "Use your image-reading tool to inspect this image." : "Read the full UTF-8 text file."),
                    ]
                    if let conversion = file.attachment.conversion {
                        details["conversion"] = .object([
                            "sourceName": .string(conversion.sourceName),
                            "sourceSHA256": .string(conversion.sourceSHA256),
                            "description": .string(conversion.description),
                        ])
                    }
                    return .object(details)
                }),
            ])
        } catch let error as AgentWorkflowError {
            return denied(request.id, error.localizedDescription)
        } catch {
            return .internalError(id: request.id, "Could not verify the workflow attachments: \(error.localizedDescription)")
        }
    }
}
