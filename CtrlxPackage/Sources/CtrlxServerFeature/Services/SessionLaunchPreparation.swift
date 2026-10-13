import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import CtrlxPluginProtocol

/// Shared Host-side preparation for local and remote session creation. Does no
/// tmux mutation: bad paths and declined explicit launches fail before creation.
struct SessionLaunchPreparation: Sendable {
    let workingDirectory: String?
    let launch: LaunchCommand?
    let createdWorktreeDirectory: String?
    private let forkEnvironmentToUnset: [String]?

    init(workingDirectory: String?, launch: LaunchCommand?, createdWorktreeDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
        self.launch = launch
        self.createdWorktreeDirectory = createdWorktreeDirectory
        forkEnvironmentToUnset = nil
    }

    init(workingDirectory: String, fork: AgentForkLaunch) {
        self.workingDirectory = workingDirectory
        launch = fork.command
        createdWorktreeDirectory = nil
        forkEnvironmentToUnset = fork.unsetEnvironment
    }

    var runCommand: String? {
        launch.map { command in
            // Keep simple command names bare so existing shell aliases still
            // expand. Paths with spaces/metacharacters are a single shell word.
            let executable = command.command.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil
                ? command.command : command.command.posixSingleQuoted
            return ([executable] + command.args.map(\.posixSingleQuoted)).joined(separator: " ")
        }
    }

    var extraEnvironment: [String] {
        // Fork overrides belong only to the scoped invocation, not its parent shell.
        guard forkEnvironmentToUnset == nil else { return [] }
        return launch?.env.map { "\($0.key)=\($0.value)" } ?? []
    }

    func forkRunCommand(shell: String) throws -> String? {
        guard let runCommand, let forkEnvironmentToUnset, let launch else { return runCommand }
        let statements: [String]
        switch (shell as NSString).lastPathComponent {
        case "zsh", "bash", "sh", "dash", "ksh":
            statements = forkEnvironmentToUnset.map { "unset \($0.posixSingleQuoted)" }
                + launch.env.keys.sorted().map { "export \("\($0)=\(launch.env[$0, default: ""])".posixSingleQuoted)" }
            guard !statements.isEmpty else { return runCommand }
            // Keep aliases/telemetry functions in the same shell, with overrides
            // scoped to this Agent invocation rather than its eventual prompt.
            return "( " + (statements + [runCommand]).joined(separator: " && ") + " )"
        default:
            throw AgentForkError("Fork cannot preserve the configuration root in shell '\(shell)'. Use zsh or bash.")
        }
    }

    static func prepare(
        path: String?,
        pluginID: String,
        requireAgentLaunch: Bool,
        core: (any PluginCore)?,
        worktree: ForkAgentSession.Worktree? = nil
    ) async throws -> Self {
        let requireAgentLaunch = requireAgentLaunch || worktree != nil
        guard let path else {
            guard !requireAgentLaunch else { throw LaunchError.missingDirectory }
            return Self(workingDirectory: nil, launch: nil)
        }
        @Dependency(SessionDirectoryClient.self) var directories
        let directory = try await directories.resolve(path)
        if requireAgentLaunch && core == nil { throw LaunchError.unavailable(pluginID) }
        let launch = await core?.commandForLaunch(projectPath: directory)
        if requireAgentLaunch && launch == nil { throw LaunchError.autoRunDisabled(pluginID) }
        guard let worktree else { return Self(workingDirectory: directory, launch: launch) }
        @Dependency(AgentForkWorktreeClient.self) var worktrees
        let destination = try await worktrees.create(directory, worktree)
        let prepared = await Self(workingDirectory: destination, launch: core?.commandForLaunch(projectPath: destination), createdWorktreeDirectory: destination)
        guard prepared.launch != nil else {
            throw AgentForkError(prepared.failureDescription(LaunchError.autoRunDisabled(pluginID)))
        }
        return prepared
    }

    static func inspectWorktree(path: String) async throws -> AgentForkWorktree {
        @Dependency(SessionDirectoryClient.self) var directories
        @Dependency(AgentForkWorktreeClient.self) var worktrees
        let directory = try await directories.resolve(path)
        return try await worktrees.inspect(directory)
    }

    func failureDescription(_ error: any Error) -> String {
        error.localizedDescription + (createdWorktreeDirectory.map { "\nThe new worktree is kept at \($0). Check it before retrying." } ?? "")
    }

    enum LaunchError: Error, LocalizedError {
        case missingDirectory
        case unavailable(String)
        case autoRunDisabled(String)

        var errorDescription: String? {
            switch self {
            case .missingDirectory: "Choose a directory on the Host before starting an agent."
            case let .unavailable(id): "Agent '\(id)' is unavailable on this Host. Enable it in Settings → Agents."
            case let .autoRunDisabled(id):
                "Agent '\(id)' declined the launch. Enable Auto-run in the Host's Settings → Agents and retry."
            }
        }
    }
}
