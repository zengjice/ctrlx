import Foundation

/// Hidden shortcut IDs. Models and efforts discovered later remain visible.
public struct AgentModelShortcuts: Codable, Equatable, Sendable {
    public var models: Set<String>
    public var efforts: Set<String>

    public init(models: Set<String> = [], efforts: Set<String> = []) {
        self.models = models
        self.efforts = efforts
    }

    public func shows(model: AgentModelOption, selection: AgentModelSelection?) -> Bool {
        model.id == selection?.model || !models.contains(model.id)
    }

    public func shows(effort: String, selection: AgentModelSelection?) -> Bool {
        effort == selection?.effort || !efforts.contains(effort)
    }
}

/// Host-owned display preferences. Optional revision keeps existing workspace snapshots readable.
public struct AgentModelShortcutPreferences: Codable, Equatable, Sendable {
    public var hidden: AgentModelShortcuts
    public var defaults: AgentModelShortcuts?
    public var revision: UInt64?

    public init(hidden: AgentModelShortcuts, defaults: AgentModelShortcuts? = nil, revision: UInt64? = nil) {
        self.hidden = hidden
        self.defaults = defaults
        self.revision = revision
    }
}

/// Replaces display preferences only; never changes the Agent's current model or effort.
public struct SetAgentModelShortcuts: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let pane: WorkspacePaneIdentity
    public let hidden: AgentModelShortcuts

    public init(pane: WorkspacePaneIdentity, hidden: AgentModelShortcuts) {
        self.pane = pane
        self.hidden = hidden
    }

    public var commandType: CommandType {
        .setAgentModelShortcuts(self)
    }
}

/// A creation-time display snapshot; never contains Provider credentials.
public struct AgentModelShortcutInitialization: Codable, Equatable, Sendable {
    public let pane: WorkspacePaneIdentity
    public let defaults: AgentModelShortcuts

    public init(pane: WorkspacePaneIdentity, defaults: AgentModelShortcuts) {
        self.pane = pane
        self.defaults = defaults
    }
}
