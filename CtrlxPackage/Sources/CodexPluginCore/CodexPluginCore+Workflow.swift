import CtrlxNetworking
import CtrlxPluginProtocol

extension CodexPluginCore: AgentWorkflowProviding {
    public nonisolated var workflowCLIVersionSupport: String? {
        distribution.automationVersionPolicy.supportedVersions
    }

    public nonisolated func supportsWorkflowCLI(_ version: String) -> Bool {
        distribution.automationVersionPolicy.supports(version)
    }

    public nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: distribution == .codex ? "› " : "❯ ", dimPlaceholder: distribution == .codex ? "Ask Codex to do anything" : "Ask TRAE CLI to do anything", allowsAnyDimPlaceholder: distribution == .traex, pendingInputHints: ["Queued follow-up inputs"])
    }

    public nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 256 * 1_024, mediaTypes: ["image/png", "image/jpeg"])
    }

    public nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        CodexWorkflowTranscript(conversationID: conversationID, nativeTurnID: nativeTurnID, agentName: distribution.displayName)
    }
}
