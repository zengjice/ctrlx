import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

/// Shared Host-side preparation for local and remote session creation. Does no
/// tmux mutation: bad paths and declined explicit launches fail before creation.
struct SessionLaunchPreparation: Sendable {
    struct AgentLaunch: Equatable, Sendable {
        let command: String
        let payload: String?
    }

    let workingDirectory: String?
    let launch: LaunchCommand?
    let createdWorktreeDirectory: String?
    private let environmentToUnset: [String]

    init(workingDirectory: String?, launch: LaunchCommand?, createdWorktreeDirectory: String? = nil) {
        self.workingDirectory = workingDirectory
        self.launch = launch
        self.createdWorktreeDirectory = createdWorktreeDirectory
        self.environmentToUnset = launch?.unsetEnvironment ?? []
    }

    init(workingDirectory: String, fork: AgentForkLaunch) {
        self.workingDirectory = workingDirectory
        self.launch = fork.command
        self.createdWorktreeDirectory = nil
        self.environmentToUnset = Self.unique(fork.command.unsetEnvironment + fork.unsetEnvironment)
    }

    static let launchPayloadOption = "@ctrlx-launch"

    /// Environment-bearing launches use a per-pane payload. The typed command is
    /// a fixed-size entry point, so shell startup cannot truncate it at the
    /// terminal's canonical-input limit. The payload is cleared before the Agent
    /// starts and is never inherited by another pane.
    func agentLaunch(shell: String, tmuxExecutable: String) throws -> AgentLaunch? {
        guard let command = launch else { return nil }
        // Keep simple command names bare so existing shell aliases still
        // expand. Paths with spaces/metacharacters are a single shell word.
        let executable = command.command.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) != nil
            ? command.command : command.command.posixSingleQuoted
        let invocation = ([executable] + command.args.map(\.posixSingleQuoted)).joined(separator: " ")
        let unset = environmentToUnset.filter { command.env[$0] == nil }
        guard !command.env.isEmpty || !unset.isEmpty else {
            return AgentLaunch(command: invocation, payload: nil)
        }
        switch (shell as NSString).lastPathComponent {
        case "zsh",
             "bash",
             "sh",
             "dash",
             "ksh":
            let script = (unset.map { "unset \($0.posixSingleQuoted)" }
                + command.env.sorted { $0.key < $1.key }.map { "export \($0.key)=\($0.value.posixSingleQuoted)" }
                + [invocation]).joined(separator: "\n") + "\n"
            return AgentLaunch(
                command: Self.payloadEntryCommand(tmuxExecutable: tmuxExecutable),
                payload: Data(script.utf8).base64EncodedString()
            )
        default:
            throw LaunchError.unsupportedShell(shell)
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func payloadEntryCommand(tmuxExecutable: String) -> String {
        let tmux = "\(tmuxExecutable.posixSingleQuoted) -S \"${TMUX%%,*}\""
        let option = launchPayloadOption.posixSingleQuoted
        return "( __ctrlx_cleanup() { \(tmux) set-option -pu -t \"$TMUX_PANE\" \(option) >/dev/null 2>&1; return 0; }; "
            + "trap '__ctrlx_cleanup' 0 1 2 15; "
            + "__ctrlx_payload=$(\(tmux) show-options -pv -t \"$TMUX_PANE\" \(option)) && "
            + "__ctrlx_cleanup && trap - 0 1 2 15 && "
            + "eval \"$(printf '%s' \"$__ctrlx_payload\" | /usr/bin/base64 -D)\" )"
    }

    static func prepare(
        path: String?,
        pluginID: String,
        requireAgentLaunch: Bool,
        core: (any PluginCore)?,
        worktree: ForkAgentSession.Worktree? = nil,
        providerID: String? = nil
    ) async throws -> Self {
        let requireAgentLaunch = requireAgentLaunch || worktree != nil
        guard let path else {
            guard !requireAgentLaunch else { throw LaunchError.missingDirectory }
            return Self(workingDirectory: nil, launch: nil)
        }
        @Dependency(SessionDirectoryClient.self) var directories
        let directory = try await directories.resolve(path)
        if requireAgentLaunch && core == nil {
            throw LaunchError.unavailable(pluginID)
        }
        let launch = try await launchCommand(
            core: core,
            projectPath: directory,
            providerID: providerID
        )
        if requireAgentLaunch && launch == nil {
            throw LaunchError.autoRunDisabled(pluginID)
        }
        guard let worktree else { return Self(workingDirectory: directory, launch: launch) }
        @Dependency(AgentForkWorktreeClient.self) var worktrees
        let destination = try await worktrees.create(directory, worktree)
        let destinationLaunch = try await launchCommand(
            core: core,
            projectPath: destination,
            providerID: providerID
        )
        let prepared = Self(
            workingDirectory: destination,
            launch: destinationLaunch,
            createdWorktreeDirectory: destination
        )
        guard prepared.launch != nil else {
            throw AgentForkError(prepared.failureDescription(LaunchError.autoRunDisabled(pluginID)))
        }
        return prepared
    }

    private static func launchCommand(
        core: (any PluginCore)?,
        projectPath: String,
        providerID: String?
    ) async throws -> LaunchCommand? {
        guard let core else {
            guard providerID == nil else {
                throw AgentProviderError("The selected Agent is unavailable on this Host.")
            }
            return nil
        }
        if let selecting = core as? any AgentProviderSelecting {
            return try await selecting.commandForLaunch(projectPath: projectPath, providerID: providerID)
        }
        guard providerID == nil else {
            throw AgentProviderError("Update this Host before choosing an Agent Provider.")
        }
        return await core.commandForLaunch(projectPath: projectPath)
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
        case unsupportedShell(String)

        var errorDescription: String? {
            switch self {
            case .missingDirectory: "Choose a directory on the Host before starting an agent."
            case let .unavailable(id): "Agent '\(id)' is unavailable on this Host. Enable it in Settings → Agents."
            case let .autoRunDisabled(id):
                "Agent '\(id)' declined the launch. Enable Auto-run in the Host's Settings → Agents and retry."
            case let .unsupportedShell(shell):
                "Agent environment overrides cannot be applied safely in shell '\(shell)'. Use zsh, bash, sh, dash or ksh."
            }
        }
    }
}
