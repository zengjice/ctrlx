import CtrlxNetworking
import Foundation

public enum AgentWorkflowTranscriptOutcome: Equatable, Sendable {
    case succeeded(String)
    case failed(String)
}

/// Consume complete JSONL records in file order. A partial trailing record is
/// retained by the reader, never interpreted as an empty or completed answer.
public protocol AgentWorkflowTranscriptParser: Sendable {
    /// Cheap byte markers locate candidate records without decoding old history.
    var startMarkers: [String] { get }
    var readsSessionHeader: Bool { get }
    func isTurnStart(_ line: Data) throws -> Bool
    /// Update Stop text without resetting the turn; return matching evidence
    /// already consumed so a late callback or inspection retry needs no replay.
    mutating func updateCandidate(_ candidate: String) -> AgentWorkflowTranscriptOutcome?
    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome?
}

public extension AgentWorkflowTranscriptParser {
    var startMarkers: [String] {
        []
    }

    var readsSessionHeader: Bool {
        false
    }

    func isTurnStart(_: Data) throws -> Bool {
        false
    }
}

/// Optional capability implemented by native Agent plugins. The Host owns I/O
/// and scheduling; each core owns its provider's durable completion semantics.
public protocol AgentWorkflowProviding: Actor {
    nonisolated var workflowCapabilities: AgentWorkflowCapabilities { get }
    nonisolated var workflowComposer: AgentWorkflowComposer { get }
    nonisolated var workflowCLIVersionSupport: String? { get }
    nonisolated func supportsWorkflowCLI(_ version: String) -> Bool
    nonisolated func workflowTranscript(
        conversationID: String,
        nativeTurnID: String,
        prompt: String,
        candidate: String
    ) -> any AgentWorkflowTranscriptParser
}

public extension AgentWorkflowProviding {
    nonisolated var workflowCLIVersionSupport: String? {
        nil
    }

    nonisolated func supportsWorkflowCLI(_: String) -> Bool {
        false
    }

    /// Version admission is separate from native hook and instance validation.
    nonisolated func workflowRuntimeIssue(cliVersion: String?) -> String? {
        guard let cliVersion, !cliVersion.isEmpty else {
            return "Cannot verify this running Agent's CLI version. Check its executable before starting a workflow."
        }
        guard supportsWorkflowCLI(cliVersion) else {
            return "Workflows do not support \(cliVersion)."
                + (workflowCLIVersionSupport.map { " Supported range: \($0)." } ?? " This plugin has no supported workflow CLI versions.")
        }
        return nil
    }
}
