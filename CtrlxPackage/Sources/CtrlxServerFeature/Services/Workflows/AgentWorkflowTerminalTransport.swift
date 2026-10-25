import CtrlxNetworking
import Foundation

/// Keeps preparation outside the input queue. The final identity/readiness
/// inspection and paste/submit share the same queue as human input.
@MainActor
final class AgentWorkflowTerminalTransport {
    private struct Prepared {
        let claim: AgentWorkflowInputGate.Claim
        let file: URL
    }

    private let store: AgentWorkflowStore
    private let gate: AgentWorkflowInputGate
    private let files: AgentWorkflowInputFiles
    private let attachmentReader = AgentWorkflowAttachmentReader()
    private let inspect: @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let submit: @MainActor @Sendable (AgentWorkflowInstance, URL, @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void) async throws -> Void
    private let onFailure: @Sendable (String) -> Void
    private var prepared: [UUID: Prepared] = [:]

    init(
        store: AgentWorkflowStore,
        gate: AgentWorkflowInputGate,
        temporaryDirectory: URL,
        inspect: @escaping @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance,
        submit: @escaping @MainActor @Sendable (AgentWorkflowInstance, URL, @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void) async throws -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.store = store
        self.gate = gate
        self.files = AgentWorkflowInputFiles(directory: temporaryDirectory)
        self.inspect = inspect
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

    private func prepare(_ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance) async throws {
        guard prepared[invocation.id] == nil else { throw AgentWorkflowError("This input is already prepared.") }
        let claim = gate.claim(paneID: instance.paneID)
        if !invocation.delivery.input.attachmentIDs.isEmpty {
            let attachments = try await store.invocationAttachments(invocation, instance: instance, status: .pending, now: Date())
            try await attachmentReader.validate(attachments)
        }
        let text = invocation.delivery.input.text
        guard
            let limit = instance.capabilities?.maximumInputBytes, text.utf8.count <= limit,
            !text.isEmpty,
            text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) else {
            throw AgentWorkflowError("The task exceeds this Agent's input limit or contains terminal control characters. Nothing was sent.")
        }
        let file = try await files.create(text)
        prepared[invocation.id] = Prepared(claim: claim, file: file)
        try Task.checkCancellation()
        try gate.validate(claim)
    }

    private func write(_ invocation: AgentWorkflowInvocation, instance: AgentWorkflowInstance) async throws {
        guard let prepared = prepared[invocation.id] else { throw AgentWorkflowInputNotWritten(reason: "The workflow input was not prepared.") }
        var committed = false
        do {
            try await gate.workflow(prepared.claim) {
                let live = try await self.inspect(instance)
                guard live.matchesBinding(instance), live.readiness == .ready else {
                    throw AgentWorkflowError("The Agent changed or its input is no longer empty. Nothing was sent.")
                }
                let authorization = try await self.store.authorizeWrite(invocation)
                try Task.checkCancellation()
                try self.gate.validate(prepared.claim)
                try await self.submit(live, prepared.file) { launch in
                    try Task.checkCancellation()
                    try self.gate.validate(prepared.claim)
                    try authorization.perform(launch)
                    committed = true
                }
            }
        } catch {
            if !committed {
                throw AgentWorkflowInputNotWritten(reason: error.localizedDescription)
            }
            throw error
        }
    }

    private func discard(_ invocationID: UUID) async {
        guard let prepared = prepared.removeValue(forKey: invocationID) else { return }
        do { try await files.remove(prepared.file) }
        catch { onFailure("Could not remove a prepared workflow input: \(error.localizedDescription)") }
    }
}

private actor AgentWorkflowInputFiles {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func create(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
