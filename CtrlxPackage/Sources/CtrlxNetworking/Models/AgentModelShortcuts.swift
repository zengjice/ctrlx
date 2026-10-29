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

/// A creation-time display snapshot; never contains Provider credentials.
public struct AgentModelShortcutInitialization: Codable, Equatable, Sendable {
    public let pane: WorkspacePaneIdentity
    public let defaults: AgentModelShortcuts

    public init(pane: WorkspacePaneIdentity, defaults: AgentModelShortcuts) {
        self.pane = pane
        self.defaults = defaults
    }
}
