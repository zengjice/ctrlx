#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import DependenciesMacros
    import Foundation

    /// These are the two bundled CLIs with an official native installer, not plugin IDs in general.
    enum InstallableAgentCLI: String, CaseIterable, Identifiable, Sendable {
        case codex
        case claudeCode = "claude-code"

        var id: String {
            rawValue
        }

        var name: String {
            self == .codex ? "Codex" : "Claude Code"
        }

        var command: String {
            self == .codex ? "codex" : "claude"
        }

        var installerURL: String {
            self == .codex ? "https://chatgpt.com/codex/install.sh" : "https://claude.ai/install.sh"
        }

        var installerShell: String {
            self == .codex ? "/bin/sh" : "/bin/bash"
        }

        var latestVersionURL: URL? {
            switch self {
            case .codex:
                URL(string: "https://registry.npmjs.org/@openai%2Fcodex/latest")
            case .claudeCode:
                URL(string: "https://registry.npmjs.org/@anthropic-ai%2Fclaude-code/latest")
            }
        }

        func nativePath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
            home.appendingPathComponent(".local/bin/\(command)").path
        }
    }

    enum AgentCLIVersion {
        static func number(in value: String) -> String? {
            value.range(of: #"\d+(?:\.\d+)+"#, options: .regularExpression).map { String(value[$0]) }
        }

        static func isNewer(_ candidate: String, than installed: String) -> Bool {
            guard
                let candidate = number(in: candidate),
                let installed = number(in: installed)
            else { return false }
            return VersionCompatibility.compare(candidate, installed) == .orderedDescending
        }
    }

    enum AgentCLIAvailability: Equatable, Sendable {
        case missing
        case available(path: String, version: String, requiresPathRepair: Bool = false)
        case unavailable(String)

        var isMissing: Bool {
            self == .missing
        }
    }

    struct AgentCLIError: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    enum AgentCLIInstallEvent: Sendable {
        case phase(String)
        case output(String)
    }

    @DependencyClient
    struct AgentCLIClient: Sendable {
        var inspect: @Sendable (InstallableAgentCLI, _ command: String) async -> AgentCLIAvailability = { _, _ in
            .unavailable("CLI detection is not configured.")
        }

        var install: @Sendable (InstallableAgentCLI, _ event: @Sendable (AgentCLIInstallEvent) async -> Void) async throws -> Void
        var managedInstallation: @Sendable (InstallableAgentCLI, _ command: String) async -> AgentCLIManagedInstallation? = { _, _ in nil }
        var maintain: @Sendable (AgentCLIMaintenanceAction, AgentCLIManagedInstallation, _ event: @Sendable (AgentCLIInstallEvent) async -> Void) async throws -> Void
        var latestVersion: @Sendable (InstallableAgentCLI) async throws -> String = { _ in
            throw AgentCLIError(message: "Update checks are not configured.")
        }
    }

    extension AgentCLIClient: DependencyKey {
        static var liveValue: Self {
            Self(
                inspect: { agent, command in
                    @Dependency(LoginShellPath.self) var loginPath
                    let path = ProcessRunner.effectivePath(resolved: loginPath.resolve(), inherited: ProcessInfo.processInfo.environment["PATH"])
                    return await inspect(agent, command: command, searchPath: path)
                },
                install: { agent, event in
                    try await AgentCLIMaintenance.installOfficial(agent, event: event)
                    guard let installation = AgentCLIManagedInstallation.discover(agent, launcherPath: agent.nativePath()) else {
                        throw AgentCLIError(message: "Installer finished, but its native installation layout could not be verified.")
                    }
                    try await AgentCLIMaintenance.repair(installation, event: event)
                },
                managedInstallation: { agent, command in
                    @Dependency(LoginShellPath.self) var loginPath
                    let path = ProcessRunner.effectivePath(resolved: loginPath.resolve(), inherited: ProcessInfo.processInfo.environment["PATH"])
                    guard let executable = executable(agent, command: command, searchPath: path)?.path else { return nil }
                    return AgentCLIManagedInstallation.discover(agent, launcherPath: executable)
                },
                maintain: { action, installation, event in
                    try await AgentCLIMaintenance.perform(action, installation: installation, event: event)
                },
                latestVersion: { agent in
                    try await latestVersion(for: agent)
                }
            )
        }

        static func latestVersion(for agent: InstallableAgentCLI) async throws -> String {
            guard let url = agent.latestVersionURL else {
                throw AgentCLIError(message: "The release source for \(agent.name) is invalid.")
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw AgentCLIError(message: "The \(agent.name) release source did not respond successfully.")
            }
            guard data.count <= 64 * 1_024 else {
                throw AgentCLIError(message: "The \(agent.name) release response is unexpectedly large.")
            }
            struct Release: Decodable { let version: String }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard let version = AgentCLIVersion.number(in: release.version) else {
                throw AgentCLIError(message: "The \(agent.name) release source returned an invalid version.")
            }
            return version
        }

        /// An explicitly configured command is authoritative. A broken command is not a missing installation.
        static func inspect(
            _ agent: InstallableAgentCLI, command: String, searchPath: String,
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) async -> AgentCLIAvailability {
            guard let resolved = executable(agent, command: command, searchPath: searchPath, home: home) else {
                return .missing
            }
            let executable = resolved.path
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                return .unavailable("Configured command is missing or not executable: \(command). Check its path in Agents settings.")
            }
            do {
                let output = VersionOutput()
                let exit = try await AgentCLIProcess.run(executable: executable, arguments: ["--version"], environment: ["PATH": searchPath], timeout: 5, output: { await output.append($0) })
                let version = await output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard exit == 0, !version.isEmpty else {
                    return .unavailable("\(executable) could not report its version (exit \(exit)). Check the command in Agents settings.")
                }
                return .available(path: executable, version: String(version.prefix(200)), requiresPathRepair: resolved.requiresPathRepair)
            } catch {
                return .unavailable("Cannot run \(executable): \(error.localizedDescription)")
            }
        }

        private static func executable(
            _ agent: InstallableAgentCLI, command: String, searchPath: String,
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> (path: String, requiresPathRepair: Bool)? {
            let explicitPath = command.contains("/")
            let commandCandidates = explicitPath ? [NSString(string: command).expandingTildeInPath]
                : searchPath.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(command).path }
            var candidates = commandCandidates
            if command == agent.command {
                candidates += [agent.nativePath(home: home), "/opt/homebrew/bin/\(command)", "/usr/local/bin/\(command)"]
                if agent == .claudeCode {
                    candidates.append(home.appendingPathComponent(".claude/local/claude").path)
                }
            }
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                if command == agent.command, !candidates.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
                    return nil
                }
                return (candidates.first ?? command, false)
            }
            return (executable, !commandCandidates.contains(executable))
        }

        private actor VersionOutput {
            var text = ""
            func append(_ value: String) {
                text = String((text + value).suffix(8_192))
            }
        }
    }
#endif
