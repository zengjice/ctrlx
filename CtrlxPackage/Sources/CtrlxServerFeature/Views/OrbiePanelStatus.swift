import CtrlxNetworking

/// A projection of existing evidence, never an input authorization.
enum OrbiePanelStatus: Equatable {
    case loading
    case startupFailed(String)
    case setup
    case disabled
    case ready
    case working
    case confirming
    case verifying
    case awaitingHuman
    case terminalDraft
    case restoring
    case uncertain(String?)
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .loading: "Loading…"
        case .startupFailed: "Orbie could not start"
        case .setup: "Create Orbie on this Mac"
        case .disabled: "Orbie is disabled on this Mac"
        case .ready: "Ready to continue"
        case .working: "Working on your message…"
        case .confirming: "Confirming message delivery…"
        case .verifying: "Verifying the reply…"
        case .awaitingHuman: "Your input is needed"
        case .terminalDraft: "There is unsent input in the terminal"
        case .restoring: "Restoring the original conversation…"
        case .uncertain: "This message’s result is not confirmed"
        case .unavailable: "Check the Agent’s terminal"
        case .failed: "The message could not be completed"
        }
    }

    var detail: String? {
        switch self {
        case .awaitingHuman: "Open the Agent tab to answer its question or review its request."
        case .terminalDraft: "Send or clear the input in the Agent tab. Your panel draft is kept."
        case .uncertain: "Check the terminal before sending again. You can recheck without resending the message."
        case let .startupFailed(reason),
             let .unavailable(reason),
             let .failed(reason): reason
        case .restoring: "This panel will reconnect automatically. No duplicate tab will be created."
        case .setup: "Use your existing Agent and Provider configuration."
        case .disabled: "Your Agent, messages and draft are kept."
        default: nil
        }
    }

    var needsAttention: Bool {
        switch self {
        case .startupFailed,
             .awaitingHuman,
             .terminalDraft,
             .uncertain,
             .unavailable,
             .failed: true
        default: false
        }
    }

    static func conversation(instance: AgentWorkflowInstance?, messages: [AgentMessage], unconfirmedSubmission: Bool = false, availability: String?) -> Self {
        guard let instance else { return .unavailable(availability ?? "The Agent is starting or its saved conversation needs recovery.") }
        if let issue = instance.capabilityIssue {
            return .unavailable(issue)
        }
        if instance.readiness == .awaitingHuman {
            return .awaitingHuman
        }
        let currentMessages = messages.filter { $0.agentID == instance.agentID }
        if let pending = currentMessages.last(where: \.isPending) {
            switch pending.status {
            case .pending,
                 .writing,
                 .awaitingAcceptance: return .confirming
            case .uncertain: return .uncertain(pending.issue)
            case .running: return pending.nativeEvent?.kind == .stopCandidate ? .verifying : .working
            default: break
            }
        }
        if unconfirmedSubmission {
            return .confirming
        }
        switch instance.readiness {
        case .busy: return .working
        case .draft: return .terminalDraft
        case .unavailable: return .unavailable(instance.inputIssue ?? availability ?? "The Agent’s input cannot be verified.")
        case .awaitingHuman: return .awaitingHuman
        case .ready: break
        }
        if let availability {
            return .unavailable(availability)
        }
        if let last = currentMessages.last, last.status == .failed {
            return .failed(last.issue ?? "Open the Agent tab to review the failure.")
        }
        return .ready
    }
}

extension OrbieService {
    var panelStatus: OrbiePanelStatus {
        guard let record else { return .loading }
        guard record.enabled else { return .disabled }
        guard record.creation != nil else { return .setup }
        if isRestoring {
            return .restoring
        }
        guard record.target?.agentID == instance?.agentID, !tabClosed else {
            return .unavailable(availability ?? "Restore the original conversation to continue.")
        }
        return .conversation(instance: instance, messages: messages, unconfirmedSubmission: record.pendingMessageID != nil, availability: availability)
    }
}

extension OrbiterService {
    func panelStatus(_ record: OrbiterRecord) -> OrbiePanelStatus {
        if let id = record.agentID, restoringAgents.contains(id) {
            return .restoring
        }
        return .conversation(instance: currentInstance(record), messages: messages, availability: availability(record))
    }
}
