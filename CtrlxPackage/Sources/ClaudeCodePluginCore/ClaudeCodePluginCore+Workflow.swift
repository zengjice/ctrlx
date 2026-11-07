import CtrlxNetworking
import CtrlxPluginProtocol

extension ClaudeCodePluginCore: AgentWorkflowProviding {
    public nonisolated var workflowCLIVersionSupport: String? {
        "Claude Code 2.1.300–2.1.319 (stable)"
    }

    public nonisolated func supportsWorkflowCLI(_ version: String) -> Bool {
        version.wholeMatch(of: /2\.1\.3[01][0-9] \(Claude Code\)/) != nil
    }

    public nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: "❯ ", enclosedByRules: true, drawsInverseCursor: true)
    }

    public nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 256 * 1_024, mediaTypes: ["image/png", "image/jpeg"])
    }

    public nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        ClaudeWorkflowTranscript(conversationID: conversationID, nativeTurnID: nativeTurnID, prompt: prompt, candidate: candidate)
    }
}
