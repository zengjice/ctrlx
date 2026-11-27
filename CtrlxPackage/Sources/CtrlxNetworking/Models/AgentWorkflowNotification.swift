import Foundation

/// An additive, encrypted notification target. The transport still selects the
/// paired Host; these IDs select a run within that Host's ledger.
public struct AgentWorkflowNotificationTarget: Codable, Equatable, Hashable, Sendable {
    public let hostID: UUID
    public let runID: UUID
    public let eventID: UUID

    public init(hostID: UUID, runID: UUID, eventID: UUID) {
        self.hostID = hostID
        self.runID = runID
        self.eventID = eventID
    }

    public var userInfo: [String: String] {
        ["workflowHostID": hostID.uuidString, "workflowRunID": runID.uuidString, "workflowEventID": eventID.uuidString]
    }

    public init?(userInfo: [AnyHashable: Any]) {
        guard
            let host = userInfo["workflowHostID"] as? String, let hostID = UUID(uuidString: host),
            let run = userInfo["workflowRunID"] as? String, let runID = UUID(uuidString: run),
            let event = userInfo["workflowEventID"] as? String, let eventID = UUID(uuidString: event) else { return nil }
        self.init(hostID: hostID, runID: runID, eventID: eventID)
    }
}

/// The latest notification intent is saved with the run transition. Submitted
/// means accepted by the local notification center or sent to the Relay socket,
/// not proof that a banner was displayed on another device.
public struct AgentWorkflowNotification: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case completed
        case attention
    }

    public struct Delivery: Codable, Equatable, Sendable {
        public let destination: String
        public var attempts = 0
        public var lastAttemptAt: Date?
        public var submittedAt: Date?
        public var error: String?

        public init(destination: String) {
            self.destination = destination
        }
    }

    public let target: AgentWorkflowNotificationTarget
    public let kind: Kind
    public let name: String
    public let round: Int
    public let issue: String?
    public let createdAt: Date
    public var nodeName: String?
    public var agentID: AgentID?
    public var paneID: String?
    public var action: NotificationActionContext?
    public var approvalRequestID: String?
    public var deliveries: [Delivery]?
    public var id: UUID {
        target.eventID
    }

    public var title: String {
        if approvalRequestID != nil {
            return "\(name) · Needs approval"
        }
        return kind == .completed ? "\(name) · Workflow completed" : "\(name) · Needs attention"
    }

    public var eventType: String {
        if approvalRequestID != nil {
            return "agent.approval"
        }
        return kind == .completed ? NotificationDelivery.workflowCompletionEventType : NotificationDelivery.workflowAttentionEventType
    }

    public var body: String {
        let context = (["Round \(round)"] + (nodeName.map { [$0] } ?? [])).joined(separator: " · ")
        return issue.map { "\(context)\n\(String($0.prefix(200)))" } ?? context
    }

    public init(run: AgentWorkflowRun, hostID: UUID, kind: Kind, createdAt: Date = Date()) {
        self.target = .init(hostID: hostID, runID: run.id, eventID: UUID())
        self.kind = kind
        self.name = run.definition.name
        self.round = run.round
        self.issue = kind == .attention ? run.issue : nil
        self.createdAt = createdAt
        let call = run.invocations.last { $0.round == run.round && ($0.status == .failed || $0.status == .uncertain || $0.status == .running) }
        self.nodeName = call.flatMap { call in run.definition.nodes.first { $0.id == call.nodeID }?.name }
    }
}
