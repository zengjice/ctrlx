import CtrlxNetworking
import Foundation

/// Final input inspection and the actual write share the human-input queue.
/// Callers persist intent before entering this boundary and own its authorization.
@MainActor
final class AgentInputWriter {
    typealias Submit = @MainActor @Sendable (AgentWorkflowInstance, URL, [URL], @escaping @MainActor @Sendable (@Sendable () throws -> Void) throws -> Void, @escaping @MainActor @Sendable ([Int]) async throws -> Void) async throws -> Void
    let gate: AgentWorkflowInputGate
    private let inspect: @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance
    private let submit: Submit

    init(gate: AgentWorkflowInputGate, inspect: @escaping @MainActor @Sendable (AgentWorkflowInstance) async throws -> AgentWorkflowInstance, submit: @escaping Submit) {
        self.gate = gate
        self.inspect = inspect
        self.submit = submit
    }

    static func validate(_ text: String, instance: AgentWorkflowInstance) throws {
        guard
            let limit = instance.capabilities?.maximumInputBytes, text.utf8.count <= limit,
            !text.isEmpty,
            text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) else {
            throw AgentWorkflowError("The message exceeds this Agent's input limit or contains terminal control characters. Nothing was sent.")
        }
    }

    func write(
        instance: AgentWorkflowInstance,
        file: URL,
        images: [URL],
        claim: AgentWorkflowInputGate.Claim,
        authorize: @escaping @MainActor @Sendable () async throws -> AgentWorkflowWriteAuthorization,
        configure: (@MainActor @Sendable (AgentWorkflowInstance, AgentWorkflowWriteAuthorization) async throws -> Void)? = nil,
        imagesReady: @escaping @MainActor @Sendable ([Int]) async throws -> Void = { _ in }
    ) async throws {
        var committed = false
        do {
            try await gate.workflow(claim) {
                let live = try await self.inspect(instance)
                guard live.matchesBinding(instance), live.capabilityIssue == nil, live.readiness == .ready else {
                    throw AgentWorkflowError("The Agent changed or its input is no longer empty. Nothing was sent.")
                }
                let authorization = try await authorize()
                if let configure {
                    try authorization.beginConfiguration()
                    do {
                        try await configure(live, authorization)
                        authorization.endConfiguration()
                    } catch {
                        authorization.endConfiguration()
                        throw error
                    }
                    let configured = try await self.inspect(instance)
                    guard configured.matchesBinding(instance), configured.capabilityIssue == nil, configured.readiness == .ready else {
                        throw AgentWorkflowError("The Agent changed or its input is no longer empty after switching models. Nothing was sent.")
                    }
                }
                try Task.checkCancellation()
                try self.gate.validate(claim)
                try await self.submit(live, file, images, { launch in
                    try Task.checkCancellation()
                    try self.gate.validate(claim)
                    try authorization.perform(launch)
                    committed = true
                }, imagesReady)
            }
        } catch {
            if !committed {
                throw AgentWorkflowInputNotWritten(reason: error.localizedDescription)
            }
            if !images.isEmpty, error is AgentWorkflowInputNotWritten {
                throw AgentWorkflowError(error.localizedDescription)
            }
            throw error
        }
    }
}
