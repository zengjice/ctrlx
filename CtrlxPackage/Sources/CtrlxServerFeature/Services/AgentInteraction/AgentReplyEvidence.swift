import CtrlxNetworking
import CtrlxPluginProtocol

/// The shared receipt boundary. A pane routes events; only authenticated runtime,
/// exact submission and native turn/path evidence can bind a reply.
enum AgentReplyEvidence {
    static func owns(_ event: PluginEvent, instance: AgentWorkflowInstance, peer: PluginIngressPeer) -> Bool {
        instance.pluginID == event.pluginID && instance.paneID == event.tmuxPane
            && peer.contains(processID: instance.processID, runtimeID: instance.processRuntimeID)
    }

    static func submission(_ event: PluginWorkflowEvent, prompt: String, acceptedTurnID: String?) -> Bool {
        event.kind == .submitted && event.text == prompt
            && (acceptedTurnID == nil || acceptedTurnID == event.nativeTurnID)
    }

    static func turn(_ event: PluginWorkflowEvent, id: String?, path: String?) -> Bool {
        event.nativeTurnID == id && event.transcriptPath == path
    }
}
