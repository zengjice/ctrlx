import Foundation

/// A durable terminal destination. Position, process and conversation are separate evidence.
public struct AgentID: Codable, Hashable, Sendable {
    public let hostID: UUID
    public let paneID: UUID

    public init(hostID: UUID, paneID: UUID) {
        self.hostID = hostID
        self.paneID = paneID
    }

    /// Resolve only from a caller's authenticated snapshot. Never choose among duplicates.
    public func resolve<Value>(in values: [Value], identity: (Value) -> AgentID?) -> AgentResolution<Value> {
        var match: Value?
        for value in values where identity(value) == self {
            guard match == nil else { return .ambiguous }
            match = value
        }
        return match.map(AgentResolution.found) ?? .missing
    }
}

public enum AgentResolution<Value> {
    case found(Value)
    case missing
    case ambiguous

    public var value: Value? {
        guard case let .found(value) = self else { return nil }
        return value
    }
}

extension AgentResolution: Sendable where Value: Sendable { }

public extension AgentID {
    var notificationUserInfo: [String: String] {
        ["agentHostID": hostID.uuidString, "agentPaneID": paneID.uuidString]
    }

    init?(notificationUserInfo: [AnyHashable: Any]) {
        guard
            let host = notificationUserInfo["agentHostID"] as? String, let hostID = UUID(uuidString: host),
            let pane = notificationUserInfo["agentPaneID"] as? String, let paneID = UUID(uuidString: pane) else { return nil }
        self.init(hostID: hostID, paneID: paneID)
    }
}
