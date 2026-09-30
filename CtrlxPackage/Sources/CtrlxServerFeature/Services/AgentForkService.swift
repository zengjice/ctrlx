import CtrlxNetworking
import Dependencies
import Foundation
import GallagerPluginProtocol

/// One Host-side path for local menus and encrypted Viewer commands.
@MainActor
final class AgentForkService {
    private let source: (String) -> AgentForkSource?
    private let core: (String) -> (any AgentSessionForking)?
    private let refresh: () async -> Void
    private let launch: (String, SessionLaunchPreparation) async throws -> String
    private var operations: [UUID: (request: ForkAgentSession, task: Task<String, Error>)] = [:]
    private var completed: [UUID] = []

    init(
        source: @escaping (String) -> AgentForkSource?,
        core: @escaping (String) -> (any AgentSessionForking)?,
        refresh: @escaping () async -> Void,
        launch: @escaping (String, SessionLaunchPreparation) async throws -> String
    ) {
        self.source = source
        self.core = core
        self.refresh = refresh
        self.launch = launch
    }

    func prepare(_ expected: AgentForkSource) async throws -> AgentForkPreparation {
        await refresh()
        let agent = try validate(expected)
        _ = try await agent.commandForFork(sessionID: expected.sessionID, projectPath: expected.workingDirectory)
        @Dependency(AgentForkWorktreeClient.self) var worktrees
        do {
            let plan = try await worktrees.inspect(expected.workingDirectory)
            return AgentForkPreparation(source: expected, worktree: plan)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return AgentForkPreparation(source: expected, worktree: nil, worktreeUnavailableReason: error.localizedDescription)
        }
    }

    func fork(_ request: ForkAgentSession) async throws -> String {
        if let operation = operations[request.requestID] {
            guard operation.request == request else { throw AgentForkError("A Fork retry must use the same source and destination.") }
            return try await operation.task.value
        }
        let task = Task { try await perform(request) }
        operations[request.requestID] = (request, task)
        defer {
            completed.append(request.requestID)
            if completed.count > 128 { operations.removeValue(forKey: completed.removeFirst()) }
        }
        return try await task.value
    }

    private func perform(_ request: ForkAgentSession) async throws -> String {
        await refresh()
        let agent = try validate(request.source)
        @Dependency(SessionDirectoryClient.self) var directories
        let sourceDirectory = try await directories.resolve(request.source.workingDirectory)
        let command = try await agent.commandForFork(sessionID: request.source.sessionID, projectPath: sourceDirectory)
        _ = try validate(request.source)
        var directory = sourceDirectory
        if let worktree = request.worktree {
            @Dependency(AgentForkWorktreeClient.self) var worktrees
            directory = try await worktrees.create(sourceDirectory, worktree)
        }
        do {
            await refresh()
            _ = try validate(request.source)
            // Only the new pane receives this command. Source state and keys are untouched.
            let forkCommand = request.worktree == nil ? command : try await agent.commandForFork(sessionID: request.source.sessionID, projectPath: directory)
            _ = try validate(request.source)
            return try await launch(request.source.sessionName, SessionLaunchPreparation(workingDirectory: directory, fork: forkCommand))
        } catch {
            throw AgentForkError(error.localizedDescription + (request.worktree == nil ? "" : "\nThe new worktree is kept at \(directory). Check it before retrying."))
        }
    }

    private func validate(_ expected: AgentForkSource) throws -> any AgentSessionForking {
        guard source(expected.paneID) == expected else {
            throw AgentForkError("The source pane, conversation or directory changed. Reopen Fork for the current Agent.")
        }
        guard let agent = core(expected.pluginID) else { throw AgentForkError("This Agent is unavailable or does not support native Fork.") }
        return agent
    }
}
