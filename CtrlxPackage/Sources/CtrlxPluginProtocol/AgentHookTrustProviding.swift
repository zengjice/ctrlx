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
    func trustHooks(terminal: AgentHookTrustTerminal) async throws -> AgentHookTrustResult
}

public struct AgentHookTrustError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
