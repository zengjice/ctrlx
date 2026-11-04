import CtrlxNetworking
import Foundation
import Synchronization

/// Serializes terminal mutations from local keys, Viewer input and workflow
/// submissions. Running workflows reject edits until an operator takes over.
@MainActor
final class AgentWorkflowInputGate {
    struct Claim: Sendable {
        let paneID: String
        let generation: UInt64
        let humanAuthorization: AgentWorkflowHumanInputAuthorization?
    }

    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var generations: [String: UInt64] = [:]
    private var tails: [String: Tail] = [:]
    private let authorizeHumanInput: @MainActor @Sendable (String) async throws -> AgentWorkflowHumanInputAuthorization

    init(authorizeHumanInput: @escaping @MainActor @Sendable (String) async throws -> AgentWorkflowHumanInputAuthorization) {
        self.authorizeHumanInput = authorizeHumanInput
    }

    func claim(paneID: String, humanAuthorization: AgentWorkflowHumanInputAuthorization? = nil) -> Claim {
        .init(paneID: paneID, generation: generations[paneID, default: 0], humanAuthorization: humanAuthorization)
    }

    func human<Value: Sendable>(
        paneID: String,
        editsInput: Bool = true,
        operation: @escaping @MainActor @Sendable (AgentWorkflowHumanInputAuthorization?) async throws -> Value
    ) async throws -> Value {
        let authorization: AgentWorkflowHumanInputAuthorization?
        if editsInput {
            authorization = try await authorizeHumanInput(paneID)
            try authorization?.validate()
            generations[paneID, default: 0] &+= 1
        } else {
            authorization = nil
        }
        return try await enqueue(paneID: paneID) {
            if editsInput {
                // A run may have started or resumed while this input was queued.
                _ = try await self.authorizeHumanInput(paneID)
                try authorization?.validate()
            }
            return try await operation(authorization)
        }
    }

    func workflow<Value: Sendable>(
        _ claim: Claim,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await enqueue(paneID: claim.paneID) {
            try self.validate(claim)
            return try await operation()
        }
    }

    func validate(_ claim: Claim) throws {
        guard generations[claim.paneID, default: 0] == claim.generation else {
            throw AgentWorkflowError("Terminal input changed before submission. Nothing was submitted by the workflow.")
        }
        try claim.humanAuthorization?.validate()
    }

    func perform(_ claim: Claim, write: () throws -> Void) throws {
        try validate(claim)
        if let authorization = claim.humanAuthorization {
            try authorization.perform(write)
        } else {
            try write()
        }
    }

    private func enqueue<Value: Sendable>(
        paneID: String,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tails[paneID]?.task
        let id = UUID()
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tails[paneID] = Tail(id: id, task: Task { _ = await work.result })
        defer {
            if tails[paneID]?.id == id {
                tails.removeValue(forKey: paneID)
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Only complete batches of viewing events may pass the read-only gate.
    static func editsInput(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("\u{1b}[") else { return true }
        return text.components(separatedBy: "\u{1b}[").dropFirst().contains { report in
            if report == "I" || report == "O" {
                return false
            }
            guard report.first == "<", report.last == "M" || report.last == "m" else { return true }
            let fields = report.dropFirst().dropLast().split(separator: ";", omittingEmptySubsequences: false)
            guard fields.count == 3, let button = UInt(fields[0]), UInt(fields[1]) != nil, UInt(fields[2]) != nil else { return true }
            return button & 64 == 0 && button & 32 == 0
        }
    }
}

/// Continue/start revoke this permit at the same synchronous boundary as a
/// process launch or control-pipe write. Already-sent input remains in flight.
final class AgentWorkflowHumanInputAuthorization: Sendable {
    private let allowed = Mutex(true)

    func validate() throws {
        try perform { }
    }

    func perform(_ write: () throws -> Void) throws {
        try allowed.withLock { value in
            guard value else { throw AgentWorkflowInputReadOnlyError() }
            try write()
        }
    }

    func revoke() {
        allowed.withLock { $0 = false }
    }
}

struct AgentWorkflowInputReadOnlyError: LocalizedError {
    var errorDescription: String? {
        "This Agent is read-only while its workflow is running. Use the control button in the Agent tab to take over before entering input."
    }
}
