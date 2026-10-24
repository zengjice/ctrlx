import CtrlxNetworking
import Foundation

public enum AgentWorkflowTranscriptOutcome: Equatable, Sendable {
    case succeeded(String)
    case failed(String)
}

/// Consume complete JSONL records in file order. A partial trailing record is
/// retained by the reader, never interpreted as an empty or completed answer.
public protocol AgentWorkflowTranscriptParser: Sendable {
    mutating func consume(_ line: Data) throws -> AgentWorkflowTranscriptOutcome?
}

/// Optional capability implemented by native Agent plugins. The Host owns I/O
/// and scheduling; each core owns its provider's durable completion semantics.
public protocol AgentWorkflowProviding: Actor {
    nonisolated var workflowCapabilities: AgentWorkflowCapabilities { get }
    nonisolated var workflowComposer: AgentWorkflowComposer { get }
    nonisolated var workflowCLIVersions: [String] { get }
    nonisolated func workflowTranscript(
        conversationID: String,
        nativeTurnID: String,
        prompt: String,
        candidate: String
    ) -> any AgentWorkflowTranscriptParser
}

public extension AgentWorkflowProviding {
    nonisolated var workflowCLIVersions: [String] {
        []
    }

    /// Native hooks and transcript formats are versioned by the Agent, not the
    /// CtrlX wire protocol. Do not assume a newer CLI preserves these semantics.
    nonisolated func workflowRuntimeIssue(cliVersion: String?) -> String? {
        guard let cliVersion, !cliVersion.isEmpty else {
            return "Cannot verify this running Agent's CLI version. Check its executable before starting a workflow."
        }
        guard workflowCLIVersions.contains(cliVersion) else {
            let supported = workflowCLIVersions.joined(separator: ", ")
            return "Workflow input and completion are not verified for \(cliVersion)."
                + (supported.isEmpty ? " This plugin has no verified CLI builds." : " Verified build: \(supported).")
        }
        return nil
    }
}
