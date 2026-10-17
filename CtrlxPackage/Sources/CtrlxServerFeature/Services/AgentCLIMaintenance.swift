#if os(macOS)
    import Darwin
    import Dependencies
    import Foundation

    enum AgentCLIMaintenanceAction: Sendable {
        case update
        case repair
    }

    struct AgentCLIManagedInstallation: Equatable, Sendable {
        enum Source: Equatable, Sendable {
            case homebrew(prefix: String, cask: String)
            case nativeCodex(home: String)
            case nativeClaude(home: String)

            var label: String {
                switch self {
                case let .homebrew(_, cask): "Homebrew · \(cask)"
                case .nativeCodex,
                     .nativeClaude: "Official native installation"
                }
            }
        }

        let agent: InstallableAgentCLI
        let launcherPath: String
        let binaryPath: String
        let source: Source

        /// Recognize stable launchers only. Updating an immutable version path would leave
        /// the configured command pointing at the old version.
        static func discover(
            _ agent: InstallableAgentCLI, launcherPath: String,
            home: URL = FileManager.default.homeDirectoryForCurrentUser,
            brewPrefixes: [String] = ["/opt/homebrew", "/usr/local"]
        ) -> Self? {
            let launcher = URL(fileURLWithPath: launcherPath).standardizedFileURL
            let binary = launcher.resolvingSymlinksInPath()
            guard FileManager.default.isExecutableFile(atPath: binary.path), launcher.path != binary.path else { return nil }

            for prefix in brewPrefixes {
                guard launcher.path == "\(prefix)/bin/\(agent.command)" else { continue }
                let casks = agent == .codex ? ["codex"] : ["claude-code", "claude-code@latest"]
                for cask in casks {
                    let root = URL(fileURLWithPath: "\(prefix)/Caskroom/\(cask)").resolvingSymlinksInPath().path + "/"
                    guard binary.path.hasPrefix(root) else { continue }
                    let parts = binary.path.dropFirst(root.count).split(separator: "/")
                    let suffix = agent == .codex ? ["bin", "codex"] : ["claude"]
                    guard parts.count == suffix.count + 1, parts.dropFirst().map(String.init) == suffix else { continue }
                    return Self(agent: agent, launcherPath: launcher.path, binaryPath: binary.path, source: .homebrew(prefix: prefix, cask: cask))
                }
            }

            if
                agent == .codex, launcher.lastPathComponent == "codex", binary.lastPathComponent == "codex",
                binary.deletingLastPathComponent().lastPathComponent == "bin" {
                let releases = binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let standalone = releases.deletingLastPathComponent()
                let packages = standalone.deletingLastPathComponent()
                if
                    releases.lastPathComponent == "releases", standalone.lastPathComponent == "standalone", packages.lastPathComponent == "packages",
                    !launcher.path.hasPrefix(standalone.path + "/") {
                    return Self(agent: agent, launcherPath: launcher.path, binaryPath: binary.path, source: .nativeCodex(home: packages.deletingLastPathComponent().path))
                }
            }
            if
                agent == .claudeCode, launcher.path == agent.nativePath(home: home),
                binary.deletingLastPathComponent() == home.appendingPathComponent(".local/share/claude/versions").resolvingSymlinksInPath() {
                return Self(agent: agent, launcherPath: launcher.path, binaryPath: binary.path, source: .nativeClaude(home: home.path))
            }
            return nil
        }

        func reloaded() -> Self? {
            let home: URL
            let prefixes: [String]
            switch source {
            case let .homebrew(prefix, _):
                home = FileManager.default.homeDirectoryForCurrentUser
                prefixes = [prefix]
            case let .nativeClaude(path):
                home = URL(fileURLWithPath: path)
                prefixes = []
            case .nativeCodex:
                home = FileManager.default.homeDirectoryForCurrentUser
                prefixes = []
            }
            return Self.discover(agent, launcherPath: launcherPath, home: home, brewPrefixes: prefixes)
        }

        var signedTools: [(path: String, identifier: String)] {
            if agent == .claudeCode {
                return [(binaryPath, "com.anthropic.claude-code")]
            }
            let package = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().deletingLastPathComponent().path
            return [(binaryPath, "codex"), ("\(package)/bin/codex-code-mode-host", "codex-code-mode-host"), ("\(package)/codex-path/rg", "com.openai.codex.rg")]
        }

        var quarantinePaths: [String] {
            let tools = signedTools.map(\.path)
            guard agent == .codex else { return tools }
            let package = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().deletingLastPathComponent().path
            // Do not recursively clear unknown files, other versions, or symlink targets.
            return tools + [package, "\(package)/bin", "\(package)/codex-path"]
        }

        func validateCurrent() throws {
            guard URL(fileURLWithPath: launcherPath).resolvingSymlinksInPath().path == binaryPath else {
                throw AgentCLIError(message: "The agent installation changed. Check again before retrying.")
            }
            for path in quarantinePaths {
                let url = URL(fileURLWithPath: path)
                guard url.resolvingSymlinksInPath().path == path, FileManager.default.fileExists(atPath: path) else {
                    throw AgentCLIError(message: "Unexpected or incomplete agent package: \(path). No launch repair was applied.")
                }
            }
        }
    }

    enum AgentCLIMaintenance {
        static func perform(
            _ action: AgentCLIMaintenanceAction, installation: AgentCLIManagedInstallation,
            event: @Sendable (AgentCLIInstallEvent) async -> Void
        ) async throws {
            try installation.validateCurrent()
            if action == .repair {
                try await repair(installation, event: event)
                return
            }
            await event(.phase("Updating \(installation.agent.name)"))
            switch installation.source {
            case let .homebrew(prefix, cask):
                try await run("\(prefix)/bin/brew", ["upgrade", "--cask", cask], environment: ["HOMEBREW_NO_INSTALL_CLEANUP": "1"], timeout: 20 * 60, event: event)
            case let .nativeCodex(home):
                try await repair(installation, event: event)
                try await installOfficial(.codex, environment: ["CODEX_HOME": home, "CODEX_INSTALL_DIR": URL(fileURLWithPath: installation.launcherPath).deletingLastPathComponent().path], event: event)
            case .nativeClaude:
                try await repair(installation, event: event)
                await event(.phase("Updating Claude Code"))
                // The native updater preserves autoUpdatesChannel and other update policies.
                try await run(installation.binaryPath, ["update"], timeout: 20 * 60, event: event)
            }
            guard let updated = installation.reloaded(), updated.source == installation.source else {
                throw AgentCLIError(message: "Update finished, but the original installation could not be verified. Check again.")
            }
            try await repair(updated, event: event)
        }

        static func repair(_ installation: AgentCLIManagedInstallation, event: @Sendable (AgentCLIInstallEvent) async -> Void) async throws {
            try installation.validateCurrent()
            await event(.phase("Verifying official signatures"))
            let team = installation.agent == .codex ? "2DC432GLL2" : "Q6L2SF6YDW"
            // Verify every executable before changing any quarantine attribute.
            for tool in installation.signedTools {
                let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(tool.identifier)\""
                try await run("/usr/bin/codesign", ["--verify", "--strict", "-R", requirement, tool.path], timeout: 30, event: event)
            }
            try Task.checkCancellation()
            try installation.validateCurrent()
            await event(.phase("Preparing agent launch"))
            for path in installation.quarantinePaths {
                try installation.validateCurrent()
                if getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 {
                    try await run("/usr/bin/xattr", ["-d", "com.apple.quarantine", path], timeout: 10, event: event)
                } else if errno != ENOATTR {
                    throw AgentCLIError(message: "Cannot inspect download quarantine: \(path) (errno \(errno)).")
                }
            }
            await event(.output("Official signatures verified; download quarantine cleared for this installation.\n"))
        }

        static func installOfficial(
            _ agent: InstallableAgentCLI, environment: [String: String] = [:],
            event: @Sendable (AgentCLIInstallEvent) async -> Void
        ) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cli-install-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let script = directory.appendingPathComponent("install.sh")
            await event(.phase("Downloading official installer"))
            try await run("/usr/bin/curl", ["--fail", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "20", "--max-time", "120", "--output", script.path, agent.installerURL], timeout: 130, event: event)
            var env = agent == .codex ? ["CODEX_NON_INTERACTIVE": "1", "CODEX_INSTALL_DIR": URL(fileURLWithPath: agent.nativePath()).deletingLastPathComponent().path] : [:]
            env.merge(environment) { _, new in new }
            await event(.phase("Running official installer"))
            try await run(agent.installerShell, [script.path], environment: env, timeout: 20 * 60, event: event)
        }

        private static func run(
            _ executable: String, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval,
            event: @Sendable (AgentCLIInstallEvent) async -> Void
        ) async throws {
            try Task.checkCancellation()
            @Dependency(AgentCLIProcessClient.self) var process
            await event(.output("\(executable) \(arguments.joined(separator: " "))\n"))
            let exit = try await process.run(executable, arguments, environment, timeout) { await event(.output($0)) }
            guard exit == 0 else {
                throw AgentCLIError(message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (exit \(exit)). See the activity log.")
            }
        }
    }
#endif
