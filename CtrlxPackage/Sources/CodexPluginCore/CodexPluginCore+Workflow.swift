import CtrlxNetworking
import CtrlxPluginProtocol

extension CodexPluginCore: AgentWorkflowProviding {
    public nonisolated var workflowCLIVersionSupport: String? {
        Self.supportedAutomationCLIVersions
    }

    public nonisolated func supportsWorkflowCLI(_ version: String) -> Bool {
        Self.supportsAutomationCLI(version)
    }

    public nonisolated var workflowComposer: AgentWorkflowComposer {
        .init(prompt: "› ", dimPlaceholder: "Ask Codex to do anything", pendingInputHints: ["Queued follow-up inputs"])
    }

    public nonisolated var workflowCapabilities: AgentWorkflowCapabilities {
        .init(maximumInputBytes: 256 * 1_024, mediaTypes: ["image/png", "image/jpeg"])
    }

    public nonisolated func workflowTranscript(conversationID: String, nativeTurnID: String, prompt: String, candidate: String) -> any AgentWorkflowTranscriptParser {
        CodexWorkflowTranscript(conversationID: conversationID, nativeTurnID: nativeTurnID)
    }
}
