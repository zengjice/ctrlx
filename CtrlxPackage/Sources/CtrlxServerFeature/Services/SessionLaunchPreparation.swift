import CtrlxCommon
import Dependencies
import Foundation
import GallagerPluginProtocol

/// Shared Host-side preparation for local and remote session creation. Does no
/// tmux mutation: bad paths and declined explicit launches fail before creation.
struct SessionLaunchPreparation: Sendable {
    let workingDirectory: String?
    let launch: LaunchCommand?

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
        launch?.env.map { "\($0.key)=\($0.value)" } ?? []
    }

    static func prepare(
        path: String?,
        pluginID: String,
        requireAgentLaunch: Bool,
        core: (any PluginCore)?
    ) async throws -> Self {
        guard let path else {
            guard !requireAgentLaunch else { throw LaunchError.missingDirectory }
            return Self(workingDirectory: nil, launch: nil)
        }
        @Dependency(SessionDirectoryClient.self) var directories
        let directory = try await directories.resolve(path)
        if requireAgentLaunch && core == nil { throw LaunchError.unavailable(pluginID) }
        let launch = await core?.commandForLaunch(projectPath: directory)
        if requireAgentLaunch && launch == nil { throw LaunchError.autoRunDisabled(pluginID) }
        return Self(workingDirectory: directory, launch: launch)
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
