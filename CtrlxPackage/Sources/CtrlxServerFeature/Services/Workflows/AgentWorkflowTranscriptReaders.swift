import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

/// Router-owned readers reuse metadata parses, independently of reply/activity
/// parsers. Only verified native record positions are used as seek hints.
actor AgentWorkflowTranscriptReaders {
    private struct Key: Hashable {
        let path: String
        let pluginID: String
        let conversationID: String
        let turnID: String
        let prompt: String
        let rejectionStart: Date?
        let rejectionEnd: Date?
        let anchor: AgentWorkflowTranscriptFile.SubmissionAnchor?
        let forDelivery: Bool
    }

    private var readers: [Key: AgentWorkflowTranscriptFile] = [:]
    private var order: [Key] = []

    func reader(
        turn: PluginWorkflowTurn, instance: AgentWorkflowInstance, prompt: String,
        provider: any AgentWorkflowProviding, rejectionWindow: Range<Date>? = nil,
        anchor: AgentWorkflowTranscriptFile.SubmissionAnchor? = nil, forDelivery: Bool = false
    ) throws -> AgentWorkflowTranscriptFile {
        let key = Key(
            path: turn.transcriptPath, pluginID: instance.pluginID, conversationID: instance.conversationID,
            turnID: turn.nativeTurnID, prompt: prompt, rejectionStart: rejectionWindow?.lowerBound,
            rejectionEnd: rejectionWindow?.upperBound, anchor: anchor, forDelivery: forDelivery
        )
        if let reader = readers[key], reader.stillAtPath(turn.transcriptPath) {
            return reader
        }
        let reader = try AgentWorkflowTranscriptFile(
            path: turn.transcriptPath,
            parser: provider.workflowTranscript(conversationID: instance.conversationID, nativeTurnID: turn.nativeTurnID, prompt: prompt, candidate: ""),
            submissionRejectionWindow: rejectionWindow, submissionAnchor: anchor
        )
        readers[key] = reader
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > 64 {
            readers.removeValue(forKey: order.removeFirst())
        }
        return reader
    }

    func delivery(
        for invocation: AgentWorkflowInvocation, turn: PluginWorkflowTurn, instance: AgentWorkflowInstance,
        receipt: AgentWorkflowPendingReceipt?, provider: any AgentWorkflowProviding
    ) async throws -> AgentWorkflowTranscriptFile.VerifiedSubmission? {
        let input = invocation.submissionText(pluginID: instance.pluginID)
        let anchor = receipt?.originalSubmissionStart.map {
            AgentWorkflowTranscriptFile.SubmissionAnchor(turnID: turn.nativeTurnID, boundary: $0, hookStartedAt: receipt?.submittedHookStartedAt)
        }
        let file = try reader(turn: turn, instance: instance, prompt: input, provider: provider, anchor: anchor, forDelivery: true)
        return try await file.verifyDelivery(turn, input: input)
    }

    func removeAll() {
        readers.removeAll()
        order.removeAll()
    }
}

extension AgentWorkflowInvocation {
    func isOriginalDelivery(_ turn: PluginWorkflowTurn, receipt: AgentWorkflowPendingReceipt?, pluginID: String) -> Bool {
        let original = receipt?.turn ?? .init(nativeTurnID: nativeTurnID ?? turn.nativeTurnID, transcriptPath: nativeTranscriptPath ?? turn.transcriptPath)
        let input = submissionText(pluginID: pluginID)
        return turn == original && (receipt?.selectedSubmission.map { receipt?.isOriginalSubmission($0, prompt: input) == true } ?? ((stepTurn?.prompt ?? input) == input))
    }
}
