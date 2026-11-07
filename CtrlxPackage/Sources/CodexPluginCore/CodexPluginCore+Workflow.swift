import CtrlxNetworking
import CtrlxPluginProtocol

extension CodexPluginCore: AgentWorkflowProviding {
    public nonisolated var workflowCLIVersionSupport: String? {
        "codex-cli 0.160.x–0.169.x (stable)"
    }

    public nonisolated func supportsWorkflowCLI(_ version: String) -> Bool {
        version.wholeMatch(of: /codex-cli 0\.16[0-9]\.(0|[1-9][0-9]*)/) != nil
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
