import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Host-created evidence, never decoded from plugin JSON. Each sink checks it
/// again after actor hops, including the automatic-response path.
struct AgentEventContext: Sendable {
    @TaskLocal static var current: AgentEventContext?

    let binding: AgentProcessBinding
    let conversationID: String

    func matches(_ pane: PaneState?, runtimeID: (String) -> String?) -> Bool {
        guard let pane else { return false }
        return pane.paneId == binding.paneID
            && binding.workspacePane.isSamePane(as: pane.workspaceIdentity)
            && pane.agentSession?.pluginID == binding.pluginID
            && pane.agentSession?.processRuntimeID == binding.runtimeID
            && pane.claudeSessionID == conversationID
            && runtimeID(binding.processID) == binding.runtimeID
    }
}

/// Only native start/submit events may change conversation. Within one live
/// process, a retired conversation cannot be resurrected by a delayed event.
struct AgentConversationEvidence {
    var runtimeID: String
    var conversationID: String
    var retired: Set<String> = []
    var latestSource: PluginIngressPeer.Process?
    var latestSequence: UInt64?

    mutating func accept(_ event: PluginEvent, nativeConversationID: String?, source: PluginIngressPeer.Process? = nil) -> Bool {
        guard nativeConversationID == nil || nativeConversationID == event.sessionID else { return false }
        let sameSource = source != nil && source?.runtimeID == latestSource?.runtimeID
        // A resident bridge keeps its counter across extension reloads. Once
        // observed, missing/replayed sequence values cannot downgrade that proof.
        if sameSource, let latestSequence {
            guard let sequence = event.sourceSequence, sequence > latestSequence else { return false }
        }
        let freshBridgeEvent = sameSource && latestSequence != nil && event.sourceSequence != nil
        let verifiedConversation = nativeConversationID == event.sessionID
        let older = source.flatMap { incoming in latestSource.map {
            incoming.startSeconds < $0.startSeconds || (incoming.startSeconds == $0.startSeconds && incoming.startMicroseconds < $0.startMicroseconds)
        }} ?? false
        if event.sessionID == conversationID {
            if !older, let source {
                latestSource = source
                latestSequence = event.sourceSequence
            }
            return true
        }
        guard verifiedConversation || !older else { return false }
        // A new kernel-observed hook process can prove an explicit native resume.
        // A resident bridge instead proves a new native session switch using
        // its ordered event counter. Codex also has open-rollout evidence.
        let freshHook = source.flatMap { incoming in latestSource.map {
            incoming.startSeconds > $0.startSeconds || (incoming.startSeconds == $0.startSeconds && incoming.startMicroseconds > $0.startMicroseconds)
        }} ?? false
        guard
            verifiedConversation || (
                (!retired.contains(event.sessionID) || freshHook || freshBridgeEvent)
                    && (event.conversationStarted == true || event.workflow?.kind == .submitted)
            ) else { return false }
        retired.insert(conversationID)
        conversationID = event.sessionID
        if !older, let source {
            latestSource = source
            latestSequence = event.sourceSequence
        }
        return true
    }
}
