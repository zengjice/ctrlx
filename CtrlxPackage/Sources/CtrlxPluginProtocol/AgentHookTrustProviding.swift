import CtrlxNetworking
import Foundation

public enum AgentHookTrustPanel: Equatable, Sendable {
    case needsReview
    case trusted
}

public enum AgentHookTrustAction: Equatable, Sendable {
    case open
    case trustAll
    case close
    case press(AgentHookTrustKey, screen: [String])
}

public enum AgentHookTrustKey: String, Sendable {
    case next = "Down"
    case details = "Enter"
    case back = "Escape"
    case toggle = "Space"
}

public struct AgentHookTrustTerminal: Sendable {
    public let read: @Sendable () async throws -> [String]
    public let perform: @Sendable (AgentHookTrustAction) async throws -> Void

    public init(read: @escaping @Sendable () async throws -> [String], perform: @escaping @Sendable (AgentHookTrustAction) async throws -> Void) {
        self.read = read
        self.perform = perform
    }
}

public protocol AgentHookTrustProviding: PluginCore {
    nonisolated var hookTrustComposer: AgentWorkflowComposer { get }
    nonisolated func hookTrustPanel(lines: [String]) -> AgentHookTrustPanel?
    nonisolated func hookTrustAllows(_ key: AgentHookTrustKey, lines: [String]) -> Bool
    func trustHooks(terminal: AgentHookTrustTerminal, refreshIfTrusted: Bool) async throws -> AgentHookTrustResult
}

public struct AgentHookTrustError: Error, LocalizedError, Sendable {
    public let message: String
    public let preservePanel: Bool
    public init(_ message: String, preservePanel: Bool = false) {
        self.message = message
        self.preservePanel = preservePanel
    }

    public var errorDescription: String? {
        message
    }
}
