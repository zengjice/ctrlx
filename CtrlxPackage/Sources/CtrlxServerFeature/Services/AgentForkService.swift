import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// One Host-side path for local menus and encrypted Viewer commands.
@MainActor
final class AgentForkService {
    private let source: @MainActor (String) -> AgentForkSource?
    private let core: @MainActor (String) -> (any AgentSessionForking)?
    private let refresh: @MainActor () async -> Void
    private let launch: @MainActor (AgentForkSource, String, SessionLaunchPreparation) async throws -> String
    private var operations: [UUID: (request: ForkAgentSession, source: AgentForkSource, task: Task<String, Error>)] = [:]
    private var completed: [UUID] = []

    init(
        source: @escaping @MainActor (String) -> AgentForkSource?,
        core: @escaping @MainActor (String) -> (any AgentSessionForking)?,
        refresh: @escaping @MainActor () async -> Void,
        launch: @escaping @MainActor (AgentForkSource, String, SessionLaunchPreparation) async throws -> String
    ) {
        self.source = source
        self.core = core
        self.refresh = refresh
        self.launch = launch
    }

    func prepare(_ expected: AgentForkSource, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws -> AgentForkPreparation {
        await refresh()
        let captured = try validatedSource(expected, identity: expectedWorkspacePane)
        let agent = try validate(captured)
        _ = try await forkCommand(agent, sessionID: captured.sessionID, projectPath: captured.workingDirectory, targetProviderID: nil)
        let providers: [AgentProviderOption]
        if let selecting = agent as? any AgentProviderSelecting {
            providers = await selecting.providerOptions()
        } else {
            providers = []
        }
        _ = try validate(captured)
        @Dependency(AgentForkWorktreeClient.self) var worktrees
        let plan: AgentForkWorktree?
        let unavailableReason: String?
        do {
            plan = try await worktrees.inspect(captured.workingDirectory)
            unavailableReason = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            plan = nil
            unavailableReason = error.localizedDescription
        }
        _ = try validate(captured)
        return AgentForkPreparation(
            source: expected,
            worktree: plan,
            worktreeUnavailableReason: unavailableReason,
            providers: providers
        )
    }

    func fork(_ request: ForkAgentSession, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws -> String {
        try request.validateName()
        await refresh()
        let captured = try validatedSource(request.source, identity: expectedWorkspacePane)
        if let operation = operations[request.requestID] {
            guard operation.request == request else { throw AgentForkError("A Fork retry must use the same source and destination.") }
            guard operation.source == captured else { throw changedSource() }
            return try await operation.task.value
        }
        let task = Task { try await perform(request, source: captured) }
        operations[request.requestID] = (request, captured, task)
        defer {
            completed.append(request.requestID)
            if completed.count > 128 {
                operations.removeValue(forKey: completed.removeFirst())
            }
        }
        return try await task.value
    }

    private func perform(_ request: ForkAgentSession, source: AgentForkSource) async throws -> String {
        let agent = try validate(source)
        @Dependency(SessionDirectoryClient.self) var directories
        let sourceDirectory: String?
        var directory: String
        if let workingDirectory = request.workingDirectory {
            sourceDirectory = nil
            directory = try await directories.resolve(workingDirectory)
        } else {
            let resolved = try await directories.resolve(source.workingDirectory)
            sourceDirectory = resolved
            directory = resolved
        }
        let command = try await forkCommand(
            agent,
            sessionID: source.sessionID,
            projectPath: directory,
            targetProviderID: request.targetProviderID
        )
        _ = try validate(source)
        if let worktree = request.worktree {
            @Dependency(AgentForkWorktreeClient.self) var worktrees
            guard let sourceDirectory else { throw AgentForkError("The source directory is unavailable.") }
            directory = try await worktrees.create(sourceDirectory, worktree)
        }
        do {
            await refresh()
            _ = try validate(source)
            // Only the new pane receives this command. Source state and keys are untouched.
            let forkCommand = request.worktree == nil ? command : try await forkCommand(
                agent,
                sessionID: source.sessionID,
                projectPath: directory,
                targetProviderID: request.targetProviderID
            )
            _ = try validate(source)
            let windowName = request.windowName ?? request.worktree?.name ?? (forkCommand.command.command as NSString).lastPathComponent.appending(" fork")
            return try await launch(source, windowName, SessionLaunchPreparation(workingDirectory: directory, fork: forkCommand))
        } catch {
            throw AgentForkError(error.localizedDescription + (request.worktree == nil ? "" : "\nThe new worktree is kept at \(directory). Check it before retrying."))
        }
    }

    private func validate(_ expected: AgentForkSource) throws -> any AgentSessionForking {
        _ = try validatedSource(expected)
        guard let agent = core(expected.pluginID) else { throw AgentForkError("This Agent is unavailable or does not support native Fork.") }
        return agent
    }

    private func forkCommand(
        _ agent: any AgentSessionForking,
        sessionID: String,
        projectPath: String,
        targetProviderID: String?
    ) async throws -> AgentForkLaunch {
        if let selecting = agent as? any AgentProviderForking {
            return try await selecting.commandForFork(
                sessionID: sessionID,
                projectPath: projectPath,
                targetProviderID: targetProviderID
            )
        }
        guard targetProviderID == nil else {
            throw AgentProviderError("This Agent does not support Forking into a different Provider.")
        }
        return try await agent.commandForFork(sessionID: sessionID, projectPath: projectPath)
    }

    private func validatedSource(_ expected: AgentForkSource, identity: WorkspacePaneIdentity? = nil) throws -> AgentForkSource {
        guard
            let current = source(expected.paneID), expected.matches(current),
            identity == nil || identity == current.workspaceIdentity else { throw changedSource() }
        return current
    }

    private func changedSource() -> AgentForkError {
        AgentForkError("The source pane, conversation or directory changed. Reopen Fork for the current Agent.")
    }
}
