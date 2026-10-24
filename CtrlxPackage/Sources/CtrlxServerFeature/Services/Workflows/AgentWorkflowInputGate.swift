import CtrlxNetworking
import Foundation

/// Serializes terminal mutations from local keys, Viewer input and workflow
/// submissions. Preparation is outside the queue, so human input invalidates a
/// prepared workflow immediately instead of waiting behind a slow attachment.
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
    private let onHumanInput: @MainActor @Sendable (String) async throws -> Void

    init(onHumanInput: @escaping @MainActor @Sendable (String) async throws -> Void) {
        self.onHumanInput = onHumanInput
    }

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
        return try await enqueue(paneID: paneID) {
            if editsInput {
                try await self.onHumanInput(paneID)
            }
            return try await operation()
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
            throw AgentWorkflowError("Human input took over this terminal. Nothing was submitted by the workflow.")
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

    /// Scrolling and focus reports don't change an Agent's task. Unknown byte
    /// sequences remain input; do not guess that arbitrary escape data is safe.
    static func editsInput(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return true }
        if text == "\u{1b}[I" || text == "\u{1b}[O" {
            return false
        }
        guard text.hasPrefix("\u{1b}[<"), text.last == "M" || text.last == "m" else { return true }
        let fields = text.dropFirst(3).dropLast().split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 3, let button = Int(fields[0]), Int(fields[1]) != nil, Int(fields[2]) != nil else { return true }
        return button & 64 == 0 && button & 32 == 0
    }
}
