#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    actor SessionLaunchTestCore: PluginCore {
        let launch: LaunchCommand?
        let launchLimit: Int?
        private(set) var paths: [String] = []
        init(launch: LaunchCommand? = nil, launchLimit: Int? = nil) {
            self.launch = launch
            self.launchLimit = launchLimit
        }

        func commandForLaunch(projectPath: String) async -> LaunchCommand? {
            paths.append(projectPath)
            if let launchLimit, paths.count > launchLimit {
                return nil
            }
            return launch
        }

        func initialize(_: PluginEnv, host _: any PluginHost) async throws { }
        func handleIngress(_: IngressFrame) async -> PluginEvent? {
            nil
        }

        func deliverResponse(sessionID _: String, requestID _: String, _: AgentResponse) async { }
        func refreshProjects() async { }
        func install(configRoot _: String?) async throws -> InstallResult {
            .alreadyInstalled
        }

        func uninstall(configRoot _: String?) async throws { }
        func installStatus(configRoot _: String?) async -> PluginInstallStatus {
            .installed(version: "1")
        }

        func applySettings(_: Data) async -> SettingsResult {
            .applied
        }

        func shutdown() async { }
    }

    struct SessionLaunchPreparationTests {
        private static let tmuxPath = "/fixture/tmux"

        private func script(for launch: SessionLaunchPreparation.AgentLaunch) throws -> String {
            let payload = try #require(launch.payload)
            let data = try #require(Data(base64Encoded: payload))
            return try #require(String(data: data, encoding: .utf8))
        }

        @Test("Simple command names preserve existing shell aliases")
        func aliases() throws {
            let preparation = SessionLaunchPreparation(workingDirectory: "/repo", launch: .init(command: "codex", args: ["-c", "otel.log_user_prompt=false"]))
            #expect(try preparation.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath)?.command == "codex '-c' 'otel.log_user_prompt=false'")
            #expect(try preparation.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath)?.payload == nil)
        }

        @Test("Ordinary launches clear inherited Provider variables but keep explicit replacements")
        func providerEnvironmentUnset() throws {
            let official = SessionLaunchPreparation(workingDirectory: "/repo", launch: .init(
                command: "claude",
                env: ["CTRLX_AGENT_PROVIDER_ID": "anthropic"],
                unsetEnvironment: ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"]
            ))
            let officialLaunch = try #require(try official.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath))
            let officialScript = try script(for: officialLaunch)
            #expect(officialScript.contains("unset 'ANTHROPIC_BASE_URL'"))
            #expect(officialScript.contains("unset 'ANTHROPIC_API_KEY'"))
            #expect(officialScript.contains("export CTRLX_AGENT_PROVIDER_ID='anthropic'"))
            #expect(officialScript.hasSuffix("claude\n"))
            #expect(officialLaunch.command.contains("show-options -pv -t \"$TMUX_PANE\" '@ctrlx-launch'"))
            #expect(officialLaunch.command.contains("set-option -pu -t \"$TMUX_PANE\" '@ctrlx-launch'"))

            let custom = SessionLaunchPreparation(workingDirectory: "/repo", launch: .init(
                command: "claude",
                env: ["ANTHROPIC_API_KEY": "fixture-key"],
                unsetEnvironment: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
            ))
            let customLaunch = try #require(try custom.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath))
            let customScript = try script(for: customLaunch)
            #expect(customScript.contains("unset 'ANTHROPIC_AUTH_TOKEN'"))
            #expect(customScript.contains("export ANTHROPIC_API_KEY='fixture-key'"))
            #expect(!customLaunch.command.contains("fixture-key"))
        }

        @Test("Launch payload is carried after rc; unsupported shells fail before creation")
        func launchPayload() throws {
            let launch = LaunchCommand(command: "codex", args: ["fork", "exact-session"], env: ["CODEX_HOME": "/selected root"])
            let ordinary = SessionLaunchPreparation(workingDirectory: "/repo", launch: launch)
            let fork = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(command: launch))
            let ordinaryLaunch = try #require(try ordinary.agentLaunch(shell: "/bin/bash", tmuxExecutable: Self.tmuxPath))
            #expect(ordinaryLaunch.command.contains("show-options -pv") == true)
            #expect(ordinaryLaunch.command.contains("set-option -pu") == true)
            #expect(ordinaryLaunch.command.contains("/selected root") == false)
            #expect(try script(for: ordinaryLaunch).contains("export CODEX_HOME='/selected root'"))
            #expect(try ordinaryLaunch == (fork.agentLaunch(shell: "/bin/bash", tmuxExecutable: Self.tmuxPath)))
            #expect(throws: SessionLaunchPreparation.LaunchError.self) { try ordinary.agentLaunch(shell: "/bin/nu", tmuxExecutable: Self.tmuxPath) }
        }

        @Test("Fork keeps Provider secrets out of the terminal command")
        func forkSecretEnvironment() throws {
            let secret = "fixture-secret-value"
            let prepared = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(
                command: LaunchCommand(
                    command: "claude",
                    env: ["ANTHROPIC_API_KEY": secret, "CTRLX_AGENT_PROVIDER_ID": "custom"],
                    unsetEnvironment: ["ANTHROPIC_API_KEY"]
                )
            ))
            let launch = try #require(try prepared.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath))
            #expect(!launch.command.contains(secret))
            let payload = try script(for: launch)
            #expect(payload.contains("export ANTHROPIC_API_KEY='fixture-secret-value'"))
            #expect(payload.contains("export CTRLX_AGENT_PROVIDER_ID='custom'"))
        }

        @Test("Fork environment is scoped and exit status is preserved in zsh and bash", arguments: ["/bin/zsh", "/bin/bash"])
        func forkShellScope(shell: String) async throws {
            let root = "/selected 'quoted' root"
            let tmux = try FakeTmuxLaunchEnvironment()
            defer { tmux.cleanup() }
            let prepared = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(
                command: LaunchCommand(command: "fork_probe", env: ["CODEX_HOME": root]),
                unsetEnvironment: ["CLAUDE_CONFIG_DIR"]
            ))
            let launch = try #require(try prepared.agentLaunch(shell: shell, tmuxExecutable: tmux.executable.path))
            try tmux.install(launch)
            let script = """
            export CODEX_HOME='/old codex root'
            export CLAUDE_CONFIG_DIR='/old claude root'
            fork_probe() {
                printf 'ROOT[%s]CLAUDE_SET[%s]\\n' "$CODEX_HOME" "${CLAUDE_CONFIG_DIR+x}"
                return 37
            }
            \(launch.command)
            printf 'EXIT[%s]AFTER[%s][%s]PAYLOAD[%s]\\n' "$?" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$([ -e \(tmux.root.path.posixSingleQuoted)/\(FakeTmuxLaunchEnvironment.pane) ] && printf set || printf unset)"
            """
            let args = shell == "/bin/zsh" ? ["-fc", script] : ["--noprofile", "--norc", "-c", script]
            let result = try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: {
                try await ProcessRunner.liveValue.run(
                    shell, args,
                    ["TMUX": "fixture,1,0", "TMUX_PANE": FakeTmuxLaunchEnvironment.pane],
                    10
                )
            }
            #expect(result.isSuccess)
            #expect(result.stdoutString.contains("ROOT[\(root)]CLAUDE_SET[]"))
            #expect(result.stdoutString.contains("EXIT[37]AFTER[/old codex root][/old claude root]PAYLOAD[unset]"))
            #expect(!tmux.containsPayload())
        }

        @Test("An ordinary Terminal never resolves a path or launches an agent")
        func terminal() async throws {
            let core = SessionLaunchTestCore(launch: .init(command: "codex"))
            let result = try await SessionLaunchPreparation.prepare(
                path: nil, pluginID: "codex", requireAgentLaunch: false, core: core
            )
            #expect(result.workingDirectory == nil)
            #expect(try result.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath) == nil)
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
                    #expect(try legacy.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath) == nil)
                }
            }
        }

        @Test("Invalid directories fail before invoking the plugin")
        func invalidDirectory() async {
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
            let base = (["/opt/Agent Tools/codex"] + args).map(\.posixSingleQuoted).joined(separator: " ")
            let launch = try #require(try result.agentLaunch(shell: "/bin/zsh", tmuxExecutable: Self.tmuxPath))
            #expect(try script(for: launch).contains(base))
            #expect(try script(for: launch).contains("export CODEX_HOME='/Host/config'"))
        }
    }

    struct SessionWorktreePreparationTests {
        private let request = ForkAgentSession.Worktree(name: "feature", expectedHead: "abc")

        @Test("Preview resolves the Host path without creating anything")
        func preview() async throws {
            try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { path in
                    #expect(path == "~/repo/src")
                    return "/Host/repo/src"
                }
                $0[AgentForkWorktreeClient.self].inspect = { directory in
                    #expect(directory == "/Host/repo/src")
                    return .init(repositoryRoot: "/Host/repo", primaryRoot: "/Host/repo", head: "abc", relativeDirectory: "src", hasUncommittedChanges: false)
                }
            } operation: {
                let plan = try await SessionLaunchPreparation.inspectWorktree(path: "~/repo/src")
                #expect(plan.relativeDirectory == "src")
            }
        }

        @Test("Worktree launch resolves the selected plugin again in the new checkout")
        func launch() async throws {
            let command = LaunchCommand(command: "custom-agent", args: ["--telemetry"], env: ["CONFIG_ROOT": "/Host/config"])
            let core = SessionLaunchTestCore(launch: command)
            let prepared = try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { _ in "/Host/repo/src" }
                $0[AgentForkWorktreeClient.self].create = { directory, worktree in
                    #expect(directory == "/Host/repo/src")
                    #expect(worktree == request)
                    return "/Host/repo/.worktrees/feature/src"
                }
            } operation: {
                try await SessionLaunchPreparation.prepare(path: "~/repo/src", pluginID: "custom-agent", requireAgentLaunch: true, core: core, worktree: request)
            }
            #expect(await core.paths == ["/Host/repo/src", "/Host/repo/.worktrees/feature/src"])
            #expect(prepared.workingDirectory == "/Host/repo/.worktrees/feature/src")
            #expect(prepared.launch?.command == command.command)
            #expect(prepared.launch?.args == command.args)
            #expect(prepared.failureDescription(AgentForkError("tmux failed")).contains("kept at /Host/repo/.worktrees/feature/src"))
        }

        @Test("Unavailable agents reject worktrees before Git even without the strict flag")
        func unavailable() async {
            await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { $0 }
            } operation: {
                for core: SessionLaunchTestCore? in [nil, SessionLaunchTestCore()] {
                    await #expect(throws: SessionLaunchPreparation.LaunchError.self) {
                        try await SessionLaunchPreparation.prepare(path: "/repo", pluginID: "custom-agent", requireAgentLaunch: false, core: core, worktree: request)
                    }
                }
                await #expect(throws: SessionLaunchPreparation.LaunchError.self) {
                    try await SessionLaunchPreparation.prepare(path: nil, pluginID: "custom-agent", requireAgentLaunch: false, core: nil, worktree: request)
                }
            }
        }

        @Test("Launch failure after checkout reports its retained path")
        func retainedCheckout() async {
            await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { $0 }
                $0[AgentForkWorktreeClient.self].create = { _, _ in "/repo/.worktrees/feature" }
            } operation: {
                do {
                    _ = try await SessionLaunchPreparation.prepare(
                        path: "/repo",
                        pluginID: "custom-agent",
                        requireAgentLaunch: true,
                        core: SessionLaunchTestCore(launch: .init(command: "agent"), launchLimit: 1),
                        worktree: request
                    )
                    Issue.record("A declined launch must fail")
                } catch {
                    #expect(error.localizedDescription.contains("declined the launch"))
                    #expect(error.localizedDescription.contains("kept at /repo/.worktrees/feature"))
                }
            }
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
            #expect(try prepared.agentLaunch(shell: "/bin/zsh", tmuxExecutable: "/fixture/tmux") == SessionLaunchPreparation(workingDirectory: nil, launch: launch).agentLaunch(shell: "/bin/zsh", tmuxExecutable: "/fixture/tmux"))
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
