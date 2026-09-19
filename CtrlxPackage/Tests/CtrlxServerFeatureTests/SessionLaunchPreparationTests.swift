#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Foundation
    import GallagerPluginProtocol
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
#endif
