import CtrlxNetworking
import Foundation

/// Used only while the workflow transport owns the pane's input queue.
struct AgentWorkflowModelInput: Sendable {
    let claim: AgentWorkflowInputGate.Claim
    let authorization: AgentWorkflowWriteAuthorization
}

/// Keeps preparation outside the input queue. The final identity/readiness
/// inspection and paste/submit share the same queue as human input.
@MainActor
final class AgentWorkflowTerminalTransport {
    private struct Prepared {
        let claim: AgentWorkflowInputGate.Claim
        let file: URL
        let images: [URL]
        let modelSelection: AgentModelSelection?
    }

    private let store: AgentWorkflowStore
    private let checkInputOwner: @Sendable (AgentID) async throws -> Void
    private let writer: AgentInputWriter
    private let gate: AgentWorkflowInputGate
    private let files: AgentInputFiles
    private let attachmentReader = AgentWorkflowAttachmentReader()
    private let inspect: @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let submit: @MainActor @Sendable (AgentWorkflowInstance, URL, [URL], @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void, @escaping @MainActor @Sendable ([Int]) async throws -> Void) async throws -> Void
    private let onFailure: @Sendable (String) -> Void
    private let configureModel: @MainActor @Sendable (AgentWorkflowInstance, AgentModelSelection, AgentWorkflowModelInput) async throws -> Void
    private let loadModels: @MainActor @Sendable (AgentWorkflowInstance) async throws -> Void
    private var prepared: [UUID: Prepared] = [:]

    init(
        store: AgentWorkflowStore,
        gate: AgentWorkflowInputGate,
        temporaryDirectory: URL,
        inspect: @escaping @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        checkInputOwner: @escaping @Sendable (AgentID) async throws -> Void = { _ in },
        loadModels: @escaping @MainActor @Sendable (AgentWorkflowInstance) async throws -> Void = { _ in },
        configureModel: @escaping @MainActor @Sendable (AgentWorkflowInstance, AgentModelSelection, AgentWorkflowModelInput) async throws -> Void = { _, _, _ in throw AgentWorkflowError("This Agent does not support step model selection.") },
        submit: @escaping @MainActor @Sendable (AgentWorkflowInstance, URL, [URL], @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void, @escaping @MainActor @Sendable ([Int]) async throws -> Void) async throws -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.checkInputOwner = checkInputOwner
        self.gate = gate
        self.writer = AgentInputWriter(gate: gate, inspect: inspect, submit: submit)
        self.files = AgentInputFiles(directory: temporaryDirectory)
        self.inspect = inspect
        self.configureModel = configureModel
        self.loadModels = loadModels
        self.submit = submit
        self.onFailure = onFailure
    }

    var transport: AgentWorkflowTransport {
        .init(
            inspect: { try await self.inspect($0) },
            prepare: { try await self.prepare($0, instance: $1) },
            write: { try await self.write($0, instance: $1) },
            discard: { await self.discard($0) }
        )
    }

    func resumeStep(_ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance) async throws {
        let text = """
        Continue the current workflow step using its existing task and instructions. If the task is already complete, do not repeat the work: run ctrlx workflow complete-step --invocation \(invocation.id.uuidString), then provide the final result. Otherwise continue the remaining work, respecting any outstanding questions or required approvals.

        [CtrlX workflow invocation: \(invocation.id.uuidString)]
        """
        guard let limit = instance.capabilities?.maximumInputBytes, text.utf8.count <= limit else {
            throw AgentWorkflowError("The continuation exceeds this Agent's input limit. Nothing was sent.")
        }
        let claim = gate.claim(paneID: instance.paneID)
        let file = try await files.create(text)
        var authorization: AgentWorkflowWriteAuthorization?
        var written = false
        var failure: (any Error)?
        do {
            try await gate.workflow(claim) {
                let live = try await self.inspect(instance)
                guard live.matchesBinding(instance) else {
                    throw AgentWorkflowError("The Agent changed. No continuation was sent.")
                }
                guard live.readiness == .ready else { return }
                try await self.checkInputOwner(live.agentID)
                guard let permit = try await self.store.authorizeContinuation(invocation, instance: live) else { return }
                authorization = permit
                try await self.submit(live, file, [], { launch in
                    try Task.checkCancellation()
                    try self.gate.validate(claim)
                    try permit.perform {
                        written = true
                        try launch()
                    }
                }, { _ in })
            }
        } catch let error as AgentWorkflowInputNotWritten {
            written = false
            failure = error
        } catch {
            failure = error
        }
        if let authorization {
            do { try await store.finishContinuation(invocation, authorization: authorization, written: written) }
            catch {
                failure = error
                onFailure("Could not save the workflow continuation outcome: \(error.localizedDescription)")
            }
        }
        do { try await files.remove(file) }
        catch {
            onFailure("Could not remove a workflow continuation input: \(error.localizedDescription)")
        }
        if let failure {
            throw failure
        }
    }

    private func prepare(_ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance) async throws {
        guard prepared[invocation.id] == nil else { throw AgentWorkflowError("This input is already prepared.") }
        let claim = gate.claim(paneID: instance.paneID)
        let modelSelection = try await store.modelSelection(for: invocation)
        if modelSelection != nil {
            try await loadModels(instance)
            try gate.validate(claim)
        }
        let text = invocation.delivery.input.text
        try AgentInputWriter.validate(text, instance: instance)
        var imageFiles: [URL] = []
        if !invocation.delivery.input.attachmentIDs.isEmpty {
            let attachments = try await store.invocationAttachments(invocation, instance: instance, status: .pending, now: Date())
            try await attachmentReader.validate(attachments)
            guard
                ["codex", "claude-code"].contains(instance.pluginID),
                attachments.allSatisfy({ ["image/png", "image/jpeg"].contains($0.attachment.mediaType) }) else {
                throw AgentWorkflowError("This Agent cannot receive native workflow images.")
            }
            do {
                for attachment in attachments {
                    try imageFiles.append(await files.create(DroppedPathFormatter.escape(path: attachment.url.path)))
                }
            } catch {
                for file in imageFiles {
                    try await files.remove(file)
                }
                throw error
            }
        }
        let file: URL
        do { file = try await files.create(text) }
        catch {
            for file in imageFiles {
                try await files.remove(file)
            }
            throw error
        }
        prepared[invocation.id] = Prepared(claim: claim, file: file, images: imageFiles, modelSelection: modelSelection)
        try Task.checkCancellation()
        try gate.validate(claim)
    }

    private func write(_ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance) async throws {
        guard let prepared = prepared[invocation.id] else { throw AgentWorkflowInputNotWritten(reason: "The workflow input was not prepared.") }
        let configure: (@MainActor @Sendable (AgentWorkflowInstance, AgentWorkflowWriteAuthorization) async throws -> Void)?
        if let selection = prepared.modelSelection {
            configure = { live, authorization in
                try await self.configureModel(live, selection, .init(claim: prepared.claim, authorization: authorization))
            }
        } else {
            configure = nil
        }
        try await writer.write(instance: instance, file: prepared.file, images: prepared.images, claim: prepared.claim, authorize: {
            try await self.checkInputOwner(instance.agentID)
            return try await self.store.authorizeWrite(invocation, numberOfWrites: prepared.images.count + 1)
        }, configure: configure, imagesReady: { numbers in
            _ = try await self.store.update(runID: invocation.delivery.runID) {
                try $0.recordImageInput(invocationID: invocation.id, numbers: numbers, now: Date())
            }
        })
    }

    private func discard(_ invocationID: UUID) async {
        guard let prepared = prepared.removeValue(forKey: invocationID) else { return }
        do {
            for file in prepared.images + [prepared.file] {
                try await files.remove(file)
            }
        } catch { onFailure("Could not remove a prepared workflow input: \(error.localizedDescription)") }
    }
}
