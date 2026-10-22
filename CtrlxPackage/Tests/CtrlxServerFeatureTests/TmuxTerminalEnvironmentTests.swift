#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxPluginProtocol
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Tmux terminal environment")
    @MainActor
    struct TmuxTerminalEnvironmentTests {
        @Test("A new session does not inherit NO_COLOR from the app")
        func clearsInheritedNoColor() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-color-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-color-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            let liveRunner = ProcessRunner.liveValue
            let noColorRunner = ProcessRunner(
                run: { executable, arguments, environment, timeout in
                    var inheritedEnvironment = environment ?? [:]
                    inheritedEnvironment["NO_COLOR"] = "1"
                    return try await liveRunner.run(
                        executable,
                        arguments,
                        inheritedEnvironment,
                        timeout
                    )
                }
            )

            try await withDependencies {
                $0[ProcessRunner.self] = noColorRunner
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                let created = try await service.createSession(
                    baseName: sessionName,
                    width: 80,
                    height: 24
                )

                let globalEnvironment = try await liveRunner.run(
                    tmuxPath,
                    ["-S", socketPath, "show-environment", "-g", "NO_COLOR"],
                    nil,
                    5
                )
                #expect(!globalEnvironment.isSuccess)
                #expect(globalEnvironment.stderrString.contains("unknown variable"))

                try await service.killSession(created.sessionName)
            }
        }

        @Test("A new window clears stale session NO_COLOR")
        func newWindowClearsStaleNoColor() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-window-color-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-window-color-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            let liveRunner = ProcessRunner.liveValue
            let created = try await liveRunner.run(
                tmuxPath,
                ["-S", socketPath, "new-session", "-d", "-s", sessionName],
                ["NO_COLOR": "1"],
                nil
            )
            try #require(created.isSuccess)

            try await withDependencies {
                $0[ProcessRunner.self] = liveRunner
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                _ = try await service.newWindow(sessionName: sessionName)

                let sessionEnvironment = try await liveRunner.run(
                    tmuxPath,
                    ["-S", socketPath, "show-environment", "-t", "=\(sessionName):", "NO_COLOR"],
                    nil,
                    5
                )
                #expect(!sessionEnvironment.isSuccess)
                #expect(sessionEnvironment.stderrString.contains("unknown variable"))
            }
        }

        @Test("A new pane clears stale session NO_COLOR")
        func splitPaneClearsStaleNoColor() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-pane-color-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-pane-color-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            let liveRunner = ProcessRunner.liveValue
            let created = try await liveRunner.run(
                tmuxPath,
                [
                    "-S", socketPath,
                    "new-session", "-d", "-s", sessionName,
                    ";",
                    "set-environment", "-t", "=\(sessionName):", "NO_COLOR", "1",
                    ";",
                    "display-message", "-p", "-t", "=\(sessionName):", "#{pane_id}",
                ],
                nil,
                nil
            )
            let paneId = created.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(created.isSuccess)
            try #require(!paneId.isEmpty)

            try await withDependencies {
                $0[ProcessRunner.self] = liveRunner
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                _ = try await service.splitPane(paneId, horizontal: true)

                let sessionEnvironment = try await liveRunner.run(
                    tmuxPath,
                    ["-S", socketPath, "show-environment", "-t", "=\(sessionName):", "NO_COLOR"],
                    nil,
                    5
                )
                #expect(!sessionEnvironment.isSuccess)
                #expect(sessionEnvironment.stderrString.contains("unknown variable"))
            }
        }

        @Test("Launch payloads use tmux stdin and pane-scoped options")
        func launchValuesUseStdin() async throws {
            let secret = "fixture-provider-key"
            let calls = LockIsolated<[[String]]>([])
            let inputs = LockIsolated<[String]>([])

            try await withDependencies {
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    calls.withValue { $0.append(arguments) }
                    let stdout = arguments.contains("new-session") ? "123:456\u{1f}%42\n" : ""
                    return ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
                }
                $0[ProcessRunner.self].runWithInput = { _, arguments, _, _, input in
                    calls.withValue { $0.append(arguments) }
                    inputs.withValue { $0.append(String(decoding: input, as: UTF8.self)) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let service = TmuxService(tmuxPath: "/fixture/tmux")
                let preparation = SessionLaunchPreparation(workingDirectory: "/repo", launch: LaunchCommand(
                    command: "codex", args: ["resume", "session"], env: ["CODEX_API_KEY": secret]
                ))
                let launch = try #require(try service.agentLaunch(preparation))
                _ = try await service.createSession(
                    baseName: "fixture",
                    width: 80,
                    height: 24,
                    runCommand: launch.command,
                    launchPayload: launch.payload
                )
            }

            #expect(!calls.value.flatMap { $0 }.contains { $0.contains(secret) })
            #expect(inputs.value.count == 1)
            #expect(!inputs.value[0].contains(secret))
            #expect(inputs.value[0].contains("set-option"))
            #expect(inputs.value[0].contains("'@ctrlx-launch'"))
            #expect(calls.value.flatMap { $0 }.contains { $0.contains("show-options -pv") })
        }

        @Test("Workspace recovery carries its payload only through the pane option")
        func workspaceRecoveryUsesStdin() async throws {
            let secret = "fixture-provider-key"
            let calls = LockIsolated<[[String]]>([])
            let inputs = LockIsolated<[String]>([])
            let pane = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%42", directory: "/repo")
            let record = WorkspaceRecoveryAgentLaunch(serverID: "fixture-server", runtimePaneID: pane.runtimeID, kind: .resume)

            try await withDependencies {
                $0[WorkspaceRecoverySystem.self].directoryExists = { _ in true }
                $0[ProcessRunner.self].run = { _, arguments, _, _ in
                    calls.withValue { $0.append(arguments) }
                    return ProcessResult(exitCode: 0, stdout: Data(record.id.uuidString.utf8), stderr: Data())
                }
                $0[ProcessRunner.self].runWithInput = { _, arguments, _, _, input in
                    calls.withValue { $0.append(arguments) }
                    inputs.withValue { $0.append(String(decoding: input, as: UTF8.self)) }
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                }
            } operation: {
                let service = TmuxService(tmuxPath: "/fixture/tmux")
                try await service.launchWorkspaceAgent(
                    runtimeID: pane.runtimeID,
                    pane: pane,
                    record: record,
                    command: AgentForkLaunch(command: LaunchCommand(
                        command: "codex", args: ["resume", "session"], env: ["CODEX_API_KEY": secret]
                    ))
                )
            }

            #expect(!calls.value.flatMap { $0 }.contains { $0.contains(secret) })
            #expect(inputs.value.count == 1)
            #expect(!inputs.value[0].contains(secret))
            #expect(inputs.value[0].contains("set-option"))
            #expect(calls.value.flatMap { $0 }.contains { $0.contains("show-options -pv") })
            #expect(calls.value.flatMap { $0 }.contains { $0.contains("/bin/zsh") })
        }

        @Test("Ctrl-C leaves no Provider credentials in the Agent shell")
        func interruptClearsProviderEnvironment() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-provider-interrupt-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-provider-interrupt-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            let fixture = try AgentFixture()
            defer { fixture.cleanup() }
            let secret = "fixture 'quoted' $(never-run)"
            let liveRunner = ProcessRunner.liveValue
            try await withDependencies {
                $0[ProcessRunner.self] = liveRunner
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                let preparation = SessionLaunchPreparation(workingDirectory: fixture.root.path, launch: LaunchCommand(
                    command: fixture.executable.path, env: ["CTRLX_PROVIDER_SECRET": secret]
                ))
                let launch = try #require(try service.agentLaunch(preparation))
                #expect(!launch.command.contains(secret))
                #expect(launch.command.utf8.count < 1_024)
                let created = try await service.createSession(
                    baseName: sessionName,
                    width: 100,
                    height: 30,
                    workingDirectory: fixture.root.path,
                    runCommand: launch.command,
                    launchPayload: launch.payload
                )

                let started = try await waitForPane(service, paneID: created.paneId, marker: "CTRLX_AGENT_STARTED")
                #expect(started.contains("CTRLX_AGENT_STARTED=[\(secret)]"))
                try await service.sendBatchKeys(created.paneId, keys: ["C-c"])
                try await Task.sleep(for: .milliseconds(300))
                try await service.sendKeys(created.paneId, keys: #"printf 'CTRLX_AFTER_SECRET=[%s]\n' "${CTRLX_PROVIDER_SECRET-unset}""#, literal: true)
                try await service.sendKeys(created.paneId, keys: "Enter")
                let after = try await waitForPane(service, paneID: created.paneId, marker: "CTRLX_AFTER_SECRET=[unset]")
                #expect(after.contains("CTRLX_AFTER_SECRET=[unset]"))

                let paneOption = try await liveRunner.run(
                    tmuxPath,
                    ["-S", socketPath, "show-options", "-pv", "-t", created.paneId, "@ctrlx-launch"],
                    nil,
                    5
                )
                #expect(!paneOption.isSuccess)
                #expect(paneOption.stderrString.contains("invalid option"))

                let sessionEnvironment = try await liveRunner.run(
                    tmuxPath,
                    ["-S", socketPath, "show-environment", "-t", "=\(created.sessionName):", "CTRLX_LAUNCH_ENV_CTRLX_PROVIDER_SECRET"],
                    nil,
                    5
                )
                #expect(!sessionEnvironment.isSuccess)
                #expect(sessionEnvironment.stderrString.contains("unknown variable"))
            }
        }

        @Test("Slow shell startup does not truncate a long Provider payload")
        func slowShellStartup() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-provider-slow-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-provider-slow-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            let files = FileManager.default
            let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ctrlx-provider-slow-\(suffix.prefix(8))")
            let dotfiles = root.appendingPathComponent("dotfiles")
            let executable = root.appendingPathComponent("agent")
            try files.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: root) }
            try Data("""
            sleep 0.4
            export CTRLX_PROVIDER_SECRET='wrong-secret'
            export CTRLX_PROVIDER_BASE='https://wrong.example.com'
            """.utf8).write(to: dotfiles.appendingPathComponent(".zshrc"))

            let secret = String(repeating: "s", count: 600)
            let base = String(repeating: "b", count: 600)
            try Data("""
            #!/bin/sh
            expected="\(secret)|\(base)"
            if [ "$CTRLX_PROVIDER_SECRET|$CTRLX_PROVIDER_BASE" = "$expected" ]; then
              printf 'CTRLX_SLOW_LAUNCH_OK\\n'
            else
              printf 'CTRLX_SLOW_LAUNCH_BAD\\n'
            fi
            """.utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                service.zdotDirOverride = dotfiles.path
                let preparation = SessionLaunchPreparation(workingDirectory: root.path, launch: LaunchCommand(
                    command: executable.path,
                    env: ["CTRLX_PROVIDER_SECRET": secret, "CTRLX_PROVIDER_BASE": base]
                ))
                let launch = try #require(try service.agentLaunch(preparation))
                #expect(launch.command.utf8.count < 1_024)
                #expect((launch.payload ?? "").utf8.count > 1_024)
                let created = try await service.createSession(
                    baseName: sessionName,
                    width: 120,
                    height: 30,
                    workingDirectory: root.path,
                    runCommand: launch.command,
                    launchPayload: launch.payload
                )
                let output = try await waitForPane(service, paneID: created.paneId, marker: "CTRLX_SLOW_LAUNCH_OK")
                #expect(output.contains("CTRLX_SLOW_LAUNCH_OK"))
                #expect(!output.contains("CTRLX_SLOW_LAUNCH_BAD"))
            }
        }

        @Test("Concurrent windows keep launch payloads pane-scoped")
        func concurrentLaunchPayloads() async throws {
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let suffix = UUID().uuidString.lowercased()
            let socketPath = "/tmp/ctrlx-provider-panes-\(suffix.prefix(8)).sock"
            let sessionName = "ctrlx-provider-panes-\(suffix)"
            defer { killTmuxServer(tmuxPath: tmuxPath, socketPath: socketPath) }

            let files = FileManager.default
            let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ctrlx-provider-panes-\(suffix.prefix(8))")
            let dotfiles = root.appendingPathComponent("dotfiles")
            let executable = root.appendingPathComponent("agent")
            try files.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            defer { try? files.removeItem(at: root) }
            try Data("""
            sleep 0.4
            """.utf8).write(to: dotfiles.appendingPathComponent(".zshrc"))
            try Data("""
            #!/bin/sh
            printf 'CTRLX_ISOLATED=[%s]\\n' "$CTRLX_PROVIDER_SECRET"
            """.utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: tmuxPath, socketPath: socketPath)
                service.zdotDirOverride = dotfiles.path
                let created = try await service.createSession(baseName: sessionName, width: 120, height: 30)

                let launchA = try #require(try service.agentLaunch(SessionLaunchPreparation(
                    workingDirectory: root.path,
                    launch: LaunchCommand(command: executable.path, env: ["CTRLX_PROVIDER_SECRET": "provider-a"])
                )))
                let launchB = try #require(try service.agentLaunch(SessionLaunchPreparation(
                    workingDirectory: root.path,
                    launch: LaunchCommand(command: executable.path, env: ["CTRLX_PROVIDER_SECRET": "provider-b"])
                )))
                let paneA = try await service.newWindow(
                    sessionName: created.sessionName,
                    workingDirectory: root.path,
                    runCommand: launchA.command,
                    launchPayload: launchA.payload,
                    forceLoginShell: true
                )
                let paneB = try await service.newWindow(
                    sessionName: created.sessionName,
                    workingDirectory: root.path,
                    runCommand: launchB.command,
                    launchPayload: launchB.payload,
                    forceLoginShell: true
                )
                let paneC = try await service.newWindow(sessionName: created.sessionName, workingDirectory: root.path)

                #expect(try await waitForPane(service, paneID: paneA, marker: "CTRLX_ISOLATED=[provider-a]").contains("CTRLX_ISOLATED=[provider-a]"))
                #expect(try await waitForPane(service, paneID: paneB, marker: "CTRLX_ISOLATED=[provider-b]").contains("CTRLX_ISOLATED=[provider-b]"))

                try await service.sendKeys(paneC, keys: #"printf 'CTRLX_PANE_INHERITED=[%s]\n' "${CTRLX_PROVIDER_SECRET-unset}""#, literal: true)
                try await service.sendKeys(paneC, keys: "Enter")
                #expect(try await waitForPane(service, paneID: paneC, marker: "CTRLX_PANE_INHERITED=[unset]").contains("CTRLX_PANE_INHERITED=[unset]"))

                for pane in [paneA, paneB] {
                    let option = try await ProcessRunner.liveValue.run(
                        tmuxPath,
                        ["-S", socketPath, "show-options", "-pv", "-t", pane, "@ctrlx-launch"],
                        nil,
                        5
                    )
                    #expect(!option.isSuccess)
                }
            }
        }

        private func waitForPane(_ service: TmuxService, paneID: String, marker: String) async throws -> String {
            for _ in 0..<50 {
                let output = try await service.capturePaneText(paneID)
                if output.contains(marker) {
                    return output
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return try await service.capturePaneText(paneID)
        }

        private struct AgentFixture {
            let root: URL
            let executable: URL

            init() throws {
                let files = FileManager.default
                self.root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ctrlx-agent-interrupt-\(UUID().uuidString.prefix(8))")
                self.executable = root.appendingPathComponent("agent")
                try files.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("""
                #!/bin/sh
                printf 'CTRLX_AGENT_STARTED=[%s]\\n' "$CTRLX_PROVIDER_SECRET"
                sleep 30
                """.utf8).write(to: executable)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }

            func cleanup() {
                try? FileManager.default.removeItem(at: root)
            }
        }

        private func killTmuxServer(tmuxPath: String, socketPath: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-S", socketPath, "kill-server"]
            process.environment = [:]
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            try? process.run()
        }
    }
#endif
