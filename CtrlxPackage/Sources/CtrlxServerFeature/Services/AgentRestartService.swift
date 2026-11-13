import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

@MainActor
final class AgentRestartService {
    private let capture: @MainActor (RestartAgentSession, WorkspacePaneIdentity?) async throws -> AgentSessionIdentity
    private let core: @MainActor (String) -> (any AgentSessionResuming)?
    private let resume: @MainActor (AgentSessionIdentity, AgentForkLaunch) async throws -> Void
    private var operations: [UUID: (request: RestartAgentSession, task: Task<Void, Error>)] = [:]
    private var completed: [UUID] = []
    private var pendingPanes: Set<String> = []

    init(
        capture: @escaping @MainActor (RestartAgentSession, WorkspacePaneIdentity?) async throws -> AgentSessionIdentity,
        core: @escaping @MainActor (String) -> (any AgentSessionResuming)?,
        resume: @escaping @MainActor (AgentSessionIdentity, AgentForkLaunch) async throws -> Void
    ) {
        self.capture = capture
        self.core = core
        self.resume = resume
    }

    func restart(_ request: RestartAgentSession, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws {
        if let operation = operations[request.requestID] {
            guard operation.request == request else { throw AgentRestartError("A restart retry must use the same Agent.") }
            return try await operation.task.value
        }
        guard pendingPanes.insert(request.source.paneID).inserted else {
            throw AgentRestartError("This Agent is already exiting and resuming. Please wait.")
        }
        let task = Task { try await perform(request, workspace: expectedWorkspacePane) }
        operations[request.requestID] = (request, task)
        defer {
            pendingPanes.remove(request.source.paneID)
            completed.append(request.requestID)
            if completed.count > 128 {
                operations.removeValue(forKey: completed.removeFirst())
            }
        }
        try await task.value
    }

    private func perform(_ request: RestartAgentSession, workspace: WorkspacePaneIdentity?) async throws {
        let proof = try await capture(request, workspace)
        guard request.matches(proof.source, runtimeID: proof.runtimeID) else { throw AgentRestartError("The Agent process changed before restart.") }
        guard let agent = core(proof.source.pluginID) else { throw AgentRestartError("This Agent does not support Resume.") }
        @Dependency(WorkspaceAgentProcessClient.self) var processes
        @Dependency(SessionDirectoryClient.self) var directories
        _ = try await directories.resolve(proof.source.workingDirectory)
        let invocation = try await processes.invocation(proof.processID, proof.runtimeID)
        let descriptor = try await agent.recoveryDescriptor(sessionID: proof.source.sessionID, projectPath: proof.source.workingDirectory, invocation: invocation)
        // Resolve history, configuration and executable before asking the Agent to exit.
        let command = try await request.logoutBeforeResume ? agent.commandForLogoutAndResume(descriptor) : agent.commandForResume(descriptor)
        let current = try await capture(request, workspace)
        guard request.matches(current.source, runtimeID: current.runtimeID), current.processID == proof.processID, current.runtimeID == proof.runtimeID else {
            throw AgentRestartError("The Agent process changed before restart. Reopen its tab's menu.")
        }
        try await resume(current, command)
    }
}
