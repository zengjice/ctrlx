import CtrlxNetworking
import Foundation

/// Secrets in the process environment stay on the Host and are never serialized.
public struct AgentModelContext: Sendable {
    public let invocation: AgentResumeInvocation
    public let environment: [String: String]
    public let directory: String

    public init(invocation: AgentResumeInvocation, environment: [String: String], directory: String) {
        self.invocation = invocation
        self.environment = environment
        self.directory = directory
    }
}

public struct AgentModelTerminal: Sendable {
    public let read: @Sendable () async throws -> [String]
    public let submit: @Sendable (String) async throws -> Void
    public let send: @Sendable ([TmuxKey]) async throws -> Void

    public init(read: @escaping @Sendable () async throws -> [String], submit: @escaping @Sendable (String) async throws -> Void, send: @escaping @Sendable ([TmuxKey]) async throws -> Void) {
        self.read = read
        self.submit = submit
        self.send = send
    }

    public static func commandBytes(_ command: String) throws -> Data {
        guard
            command == "/model" || command.hasPrefix("/model "), command.utf8.count <= 1_024,
            !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentModelError("Invalid model command.")
        }
        return Data("\u{1b}[200~\(command)\u{1b}[201~\r".utf8)
    }

    public func wait<T: Sendable>(_ parse: @Sendable ([String]) -> T?) async throws -> T {
        for _ in 0..<20 {
            try Task.checkCancellation()
            if let value = try parse(await read()) {
                return value
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentModelError("The Agent did not confirm the model change. Check its terminal before trying again.")
    }
}

/// Optional capability; sidecars and older native CLIs need not implement it.
public protocol AgentModelProviding: PluginCore {
    nonisolated var modelComposer: AgentWorkflowComposer { get }
    nonisolated func modelRuntimeIssue(_ context: AgentModelContext) -> String?
    func modelOptions(_ context: AgentModelContext) async throws -> [AgentModelOption]
    nonisolated func modelSelection(lines: [String], models: [AgentModelOption]) -> AgentModelSelection?
    nonisolated func modelSwitchIssue(lines: [String], models: [AgentModelOption]) -> String?
    nonisolated func isModelPicker(lines: [String], models: [AgentModelOption]) -> Bool
    func selectModel(_ selection: AgentModelSelection, models: [AgentModelOption], terminal: AgentModelTerminal) async throws -> AgentModelSelection
}

public extension AgentModelProviding {
    nonisolated func modelSwitchIssue(lines _: [String], models _: [AgentModelOption]) -> String? {
        nil
    }

    nonisolated func isModelPicker(lines _: [String], models _: [AgentModelOption]) -> Bool {
        false
    }
}

public struct AgentModelError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
