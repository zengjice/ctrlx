import CtrlxNetworking
import Foundation

/// Serializes terminal mutations from local keys, Viewer input and workflow
/// submissions. Human input remains available while workflows run.
@MainActor
final class AgentWorkflowInputGate {
    struct Claim: Sendable {
        let paneID: String
        let generation: UInt64
    }

    private struct Tail {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var generations: [String: UInt64] = [:]
    private var tails: [String: Tail] = [:]

    func claim(paneID: String) -> Claim {
        .init(paneID: paneID, generation: generations[paneID, default: 0])
    }

    func human<Value: Sendable>(
        paneID: String,
        editsInput: Bool = true,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        if editsInput {
            generations[paneID, default: 0] &+= 1
        }
        return try await enqueue(paneID: paneID, operation: operation)
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
    }

    func perform(_ claim: Claim, write: () throws -> Void) throws {
        try validate(claim)
        try write()
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

    /// Viewing events do not invalidate a prepared automatic submission.
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
