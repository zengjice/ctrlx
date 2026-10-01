#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import CtrlxPluginProtocol
    import Testing
    @testable import CtrlxServerFeature

    private actor SessionLaunchTestCore: PluginCore {
        let launch: LaunchCommand?
        private(set) var paths: [String] = []
        init(launch: LaunchCommand? = nil) { self.launch = launch }
        func commandForLaunch(projectPath: String) async -> LaunchCommand? {
            paths.append(projectPath)
            return launch
        }
        func initialize(_: PluginEnv, host _: any PluginHost) async throws { }
        func handleIngress(_: IngressFrame) async -> PluginEvent? { nil }
        func deliverResponse(sessionID _: String, requestID _: String, _: AgentResponse) async { }
        func refreshProjects() async { }
        func install(configRoot _: String?) async throws -> InstallResult { .alreadyInstalled }
        func uninstall(configRoot _: String?) async throws { }
        func installStatus(configRoot _: String?) async -> PluginInstallStatus { .installed(version: "1") }
        func applySettings(_: Data) async -> SettingsResult { .applied }
        func shutdown() async { }
    }

    struct SessionLaunchPreparationTests {
        @Test("Simple command names preserve existing shell aliases")
        func aliases() {
            let preparation = SessionLaunchPreparation(workingDirectory: "/repo", launch: .init(command: "codex", args: ["-c", "otel.log_user_prompt=false"]))
            #expect(preparation.runCommand == "codex '-c' 'otel.log_user_prompt=false'")
        }

        @Test("Only Fork reasserts config after rc; unsupported shells fail before creation")
        func forkEnvironment() throws {
            let launch = LaunchCommand(command: "codex", args: ["fork", "exact-session"], env: ["CODEX_HOME": "/selected root"])
            let ordinary = SessionLaunchPreparation(workingDirectory: "/repo", launch: launch)
            #expect(try ordinary.forkRunCommand(shell: "/bin/zsh") == ordinary.runCommand)
            #expect(ordinary.extraEnvironment == ["CODEX_HOME=/selected root"])
            let fork = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(command: launch))
            #expect(fork.extraEnvironment.isEmpty)
            #expect(try fork.forkRunCommand(shell: "/bin/bash") == "( export 'CODEX_HOME=/selected root' && codex 'fork' 'exact-session' )")
            #expect(throws: AgentForkError.self) { try fork.forkRunCommand(shell: "/bin/nu") }
        }

        @Test("Fork environment is scoped and exit status is preserved in zsh and bash", arguments: ["/bin/zsh", "/bin/bash"])
        func forkShellScope(shell: String) async throws {
            let root = "/selected 'quoted' root"
            let prepared = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(
                command: LaunchCommand(command: "fork_probe", env: ["CODEX_HOME": root]),
                unsetEnvironment: ["CLAUDE_CONFIG_DIR"]
            ))
            let invocation = try #require(try prepared.forkRunCommand(shell: shell))
            let script = """
            export CODEX_HOME='/old codex root'
            export CLAUDE_CONFIG_DIR='/old claude root'
            fork_probe() {
                printf 'ROOT[%s]CLAUDE_SET[%s]\\n' "$CODEX_HOME" "${CLAUDE_CONFIG_DIR+x}"
                return 37
            }
            \(invocation)
            printf 'EXIT[%s]AFTER[%s][%s]\\n' "$?" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
            """
            let args = shell == "/bin/zsh" ? ["-fc", script] : ["--noprofile", "--norc", "-c", script]
            let result = try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: {
                try await ProcessRunner.liveValue.run(shell, args, nil, 10)
            }
            #expect(result.isSuccess)
            #expect(result.stdoutString.contains("ROOT[\(root)]CLAUDE_SET[]"))
            #expect(result.stdoutString.contains("EXIT[37]AFTER[/old codex root][/old claude root]"))
        }

        @Test("An ordinary Terminal never resolves a path or launches an agent")
        func terminal() async throws {
            let core = SessionLaunchTestCore(launch: .init(command: "codex"))
            let result = try await SessionLaunchPreparation.prepare(
                path: nil, pluginID: "codex", requireAgentLaunch: false, core: core
            )
            #expect(result.workingDirectory == nil)
            #expect(result.runCommand == nil)
            #expect(await core.paths.isEmpty)
        }

        @Test("Explicit agent launches reject a missing directory")
        func missingPath() async {
            await #expect(throws: SessionLaunchPreparation.LaunchError.self) {
                try await SessionLaunchPreparation.prepare(path: nil, pluginID: "codex", requireAgentLaunch: true, core: nil)
            }
        }

        @Test("Disabled or declining agents cannot silently create a shell")
        func unavailable() async throws {
            try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { $0 }
            } operation: {
                for core: SessionLaunchTestCore? in [nil, SessionLaunchTestCore()] {
                    await #expect(throws: SessionLaunchPreparation.LaunchError.self) {
                        try await SessionLaunchPreparation.prepare(path: "/repo", pluginID: "codex", requireAgentLaunch: true, core: core)
                    }
                    let legacy = try await SessionLaunchPreparation.prepare(path: "/repo", pluginID: "codex", requireAgentLaunch: false, core: core)
                    #expect(legacy.workingDirectory == "/repo")
                    #expect(legacy.runCommand == nil)
                }
            }
        }

        @Test("Invalid directories fail before invoking the plugin")
        func invalidDirectory() async throws {
            let core = SessionLaunchTestCore(launch: .init(command: "codex"))
            await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { throw SessionDirectoryResolver.DirectoryError.notDirectory($0) }
            } operation: {
                await #expect(throws: SessionDirectoryResolver.DirectoryError.self) {
                    try await SessionLaunchPreparation.prepare(path: "/missing", pluginID: "codex", requireAgentLaunch: true, core: core)
                }
            }
            #expect(await core.paths.isEmpty)
        }

        @Test("Custom paths use the plugin's complete launch command, telemetry args and environment")
        func preservesLaunch() async throws {
            let args = ["-c", #"otel.exporter.otlp-http.endpoint="http://127.0.0.1:4318/v1/logs""#, "one'two"]
            let core = SessionLaunchTestCore(launch: .init(command: "/opt/Agent Tools/codex", args: args, env: ["CODEX_HOME": "/Host/config"]))
            let result = try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { path in
                    #expect(path == "~/new repo")
                    return "/Host/new repo"
                }
            } operation: {
                try await SessionLaunchPreparation.prepare(path: "~/new repo", pluginID: "codex", requireAgentLaunch: true, core: core)
            }
            #expect(await core.paths == ["/Host/new repo"])
            #expect(result.workingDirectory == "/Host/new repo")
            #expect(result.launch?.args == args)
            #expect(result.extraEnvironment == ["CODEX_HOME=/Host/config"])
            #expect(result.runCommand == (["/opt/Agent Tools/codex"] + args).map(\.posixSingleQuoted).joined(separator: " "))
        }
    }

    struct SessionDirectoryResolverTests {
        @Test("Host filesystem validation supports spaces and rejects missing paths/files")
        func filesystem() async throws {
            let files = FileManager.default
            let root = files.temporaryDirectory.appendingPathComponent("ctrlx-directory-test-\(UUID().uuidString)")
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: root) }
            let directory = root.appendingPathComponent("repo with 'quotes'")
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("file")
            try Data().write(to: file)
            let resolver = SessionDirectoryResolver()
            #expect(try await resolver.resolve(directory.path) == directory.standardizedFileURL.path)
            #expect(try await resolver.resolve("~") == files.homeDirectoryForCurrentUser.standardizedFileURL.path)
            for path in [file.path, root.appendingPathComponent("missing").path, "relative"] {
                await #expect(throws: SessionDirectoryResolver.DirectoryError.self) { try await resolver.resolve(path) }
            }
        }
    }

    struct TmuxWindowCreationTests {
        @Test("Terminal windows keep their original directory and never invoke a plugin")
        func terminal() async throws {
            let core = SessionLaunchTestCore(launch: .init(command: "codex"))
            let prepared = try await TmuxWindowCreation.prepare(.init(sessionName: "existing", workingDirectory: "/repo"), core: core)
            #expect(prepared.workingDirectory == "/repo")
            #expect(prepared.launch == nil)
            #expect(await core.paths.isEmpty)
        }

        @Test("Agent windows use the same Host-resolved telemetry, quoting and environment as sessions")
        func agent() async throws {
            let launch = LaunchCommand(command: "codex", args: ["-c", "otel.log_user_prompt=false", "a'b"], env: ["CODEX_HOME": "/Host/config"])
            let core = SessionLaunchTestCore(launch: launch)
            let prepared = try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { _ in "/Host/new repo" }
            } operation: {
                try await TmuxWindowCreation.prepare(.init(sessionName: "existing", workingDirectory: "~/new repo", pluginID: "codex"), core: core)
            }
            #expect(prepared.workingDirectory == "/Host/new repo")
            #expect(prepared.runCommand == SessionLaunchPreparation(workingDirectory: nil, launch: launch).runCommand)
            #expect(prepared.extraEnvironment == ["CODEX_HOME=/Host/config"])
            #expect(await core.paths == ["/Host/new repo"])
        }

        @Test("Missing/disabled agents and invalid paths fail before window creation")
        func rejected() async throws {
            await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { $0 }
            } operation: {
                for core: SessionLaunchTestCore? in [nil, SessionLaunchTestCore()] {
                    await #expect(throws: SessionLaunchPreparation.LaunchError.self) {
                        try await TmuxWindowCreation.prepare(.init(sessionName: "existing", workingDirectory: "/repo", pluginID: "codex"), core: core)
                    }
                }
            }
            await #expect(throws: SessionLaunchPreparation.LaunchError.self) {
                try await TmuxWindowCreation.prepare(.init(sessionName: "existing", pluginID: "codex"), core: nil)
            }
        }
    }
#endif
