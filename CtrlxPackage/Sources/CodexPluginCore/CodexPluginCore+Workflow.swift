import CtrlxNetworking
import CtrlxPluginProtocol

extension CodexPluginCore: AgentWorkflowProviding {
    public nonisolated var workflowCLIVersions: [String] {
        ["codex-cli 0.163.0"]
    }

    public nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: "› ", dimPlaceholder: "Ask Codex to do anything", pendingInputHints: ["Queued follow-up inputs"])
    }

    public nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 256 * 1_024, mediaTypes: ["image/png", "image/jpeg", "text/plain", "text/markdown"])
    }

    public nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        CodexWorkflowTranscript(conversationID: conversationID, nativeTurnID: nativeTurnID)
    }
}
