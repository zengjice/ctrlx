import CtrlxNetworking
import CtrlxPluginProtocol

extension ClaudeCodePluginCore: AgentWorkflowProviding {
    public nonisolated var workflowCLIVersions: [String] {
        ["2.1.308 (Claude Code)", "2.1.312 (Claude Code)", "2.1.317 (Claude Code)"]
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
