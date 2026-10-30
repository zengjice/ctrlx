import Foundation

public struct AgentModelOption: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let efforts: [String]
    public let defaultEffort: String?
    public let screenNames: [String]

    public init(id: String, name: String, efforts: [String], defaultEffort: String?, screenNames: [String] = []) {
        self.id = id
        self.name = name
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.screenNames = screenNames
    }
}

public struct AgentModelSelection: Codable, Equatable, Sendable {
    public var model: String
    public var effort: String?

    public init(model: String, effort: String?) {
        self.model = model
        self.effort = effort
    }
}

public struct AgentModelSnapshot: Codable, Equatable, Sendable {
    public let runtimeID: String
    public let models: [AgentModelOption]
    public let selection: AgentModelSelection?
    public let unavailableReason: String?
    public let catalogWarning: String?

    public init(runtimeID: String, models: [AgentModelOption], selection: AgentModelSelection?, unavailableReason: String?, catalogWarning: String? = nil) {
        self.runtimeID = runtimeID
        self.models = models
        self.selection = selection
        self.unavailableReason = unavailableReason
        self.catalogWarning = catalogWarning
    }
}

/// Read-only unless a selection is supplied. The Host revalidates the process,
/// pane identity and empty composer before executing a session-only change.
public struct AgentModelControls: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let workspacePane: WorkspacePaneIdentity
    public var runtimeID: String?
    public var selection: AgentModelSelection?
    public var expectedSelection: AgentModelSelection?
    public var refresh: Bool

    public init(workspacePane: WorkspacePaneIdentity, runtimeID: String? = nil, selection: AgentModelSelection? = nil, expectedSelection: AgentModelSelection? = nil, refresh: Bool = false) {
        self.workspacePane = workspacePane
        self.runtimeID = runtimeID
        self.selection = selection
        self.expectedSelection = expectedSelection
        self.refresh = refresh
    }

    public var commandType: CommandType {
        .agentModelControls(self)
    }
}
