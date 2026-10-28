import Foundation

/// A Host session can outlive its last terminal while human resources remain open.
public struct ResourceSession: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var directory: String

    public init(id: UUID, name: String, directory: String) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

/// Separate from legacy pane catalogs: older Viewers must never receive fake panes.
public struct IndependentResourceCatalog: Codable, Sendable, Equatable {
    public var sessions: [ResourceSession]
    public var files: [HostFileTab]
    public var browsers: [RemoteBrowserTab]
    public var simulators: [RemoteSimulatorTab]

    public init(sessions: [ResourceSession], files: [HostFileTab] = [], browsers: [RemoteBrowserTab] = [], simulators: [RemoteSimulatorTab] = []) {
        self.sessions = sessions
        self.files = files
        self.browsers = browsers
        self.simulators = simulators
    }
}

public struct ResourceAgent: Codable, Sendable, Equatable, Identifiable {
    /// Opaque identity of this running Agent, resolved and revalidated by the Host.
    public let id: String
    public let title: String
    public let paneID: String

    public init(id: String, title: String, paneID: String) {
        self.id = id
        self.title = title
        self.paneID = paneID
    }
}

public struct ResourceTabGrant: Codable, Sendable, Equatable {
    public let agent: ResourceAgent
    public var canWrite: Bool

    public init(agent: ResourceAgent, canWrite: Bool) {
        self.agent = agent
        self.canWrite = canWrite
    }
}

public enum ResourceTabKind: String, Codable, Sendable, CaseIterable {
    case files
    case browser
    case simulator
}

public struct ResourceTabRequest: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let sessionID: UUID
    public let operation: Operation

    public enum Operation: Codable, Sendable, Equatable {
        case open(kind: ResourceTabKind, location: String?)
        case agents
        case sendPath(tabID: UUID, path: String, agentID: String)
        case authorize(kind: ResourceTabKind, tabID: UUID, agentID: String)
        case revoke(kind: ResourceTabKind, tabID: UUID)
        case returnControl(kind: ResourceTabKind, tabID: UUID)
        case closeSession
    }

    public init(sessionID: UUID, operation: Operation) {
        self.sessionID = sessionID
        self.operation = operation
    }

    public var commandType: CommandType {
        .resourceTab(self)
    }
}

public struct ResourceTabResponse: Codable, Sendable, Equatable {
    public var file: HostFileTab?
    public var browser: RemoteBrowserTab?
    public var simulator: RemoteSimulatorTab?
    public var agents: [ResourceAgent]?

    public init(file: HostFileTab? = nil, browser: RemoteBrowserTab? = nil, simulator: RemoteSimulatorTab? = nil, agents: [ResourceAgent]? = nil) {
        self.file = file
        self.browser = browser
        self.simulator = simulator
        self.agents = agents
    }
}
