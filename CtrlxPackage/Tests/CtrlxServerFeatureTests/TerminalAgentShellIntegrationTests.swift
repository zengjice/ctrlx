import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct TerminalAgentShellIntegrationTests {
    private let defaults = [
        "-c", #"otel.exporter.otlp-http.endpoint="http://127.0.0.1:54321/v1/logs""#,
        "-c", #"otel.log_user_prompt=false"#,
    ]

    @Test("Only supported shells receive the zsh integration")
    func supportedShells() {
        #expect(TerminalAgentShellIntegration.supports(shell: "/bin/zsh"))
        #expect(TerminalAgentShellIntegration.supports(shell: "/opt/homebrew/bin/zsh"))
        for shell in ["/bin/bash", "/bin/sh", "/usr/local/bin/fish", "/usr/local/bin/nu"] {
            #expect(!TerminalAgentShellIntegration.supports(shell: shell))
        }
    }

    @Test("Manual Codex preserves argv, login rc, cwd, exit status and ZDOTDIR")
    func shellBehavior() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.run(defaults: defaults, command: #"""
        __ctrlx_install_codex_telemetry
        CODEX_FIXTURE_EXIT=37 codex resume --last --model 'model with spaces' -- 'literal $(touch SHOULD_NOT_EXIST); "quotes"'
        print -r -- "EXIT=$?"
        print -r -- "RC=$RC_ORDER;ZD=$ZDOTDIR;PWD=$PWD"
        print -r -- "HOOKS=${precmd_functions[*]}"
        print -r -- "INIT=${+functions[__ctrlx_install_codex_telemetry]}"
        """#)
        #expect(result.isSuccess)
        let output = result.stdoutString
        #expect(output.contains("<\(defaults[1])>"))
        #expect(output.contains("<resume>\n<--last>\n<--model>\n<model with spaces>"))
        #expect(output.contains(#"<literal $(touch SHOULD_NOT_EXIST); "quotes">"#))
        #expect(output.contains("EXIT=37"))
        #expect(output.contains("RC=env,profile,rc,login,;ZD=\(fixture.dotfiles.path);PWD=\(fixture.root.path)"))
        #expect(output.contains("HOOKS=user_prompt_hook"))
        #expect(output.contains("INIT=0"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    @Test("Explicit OTEL arguments and UI launches bypass defaults", arguments: [
        #"-c 'otel.exporter="none"'"#,
        #"--config 'otel.log_user_prompt=false'"#,
        #"--config='otel.exporter="none"'"#,
        #"-c'otel.exporter="none"'"#,
        #"-c ' otel = { exporter = "none" }'"#,
        #"-c '"otel".exporter="none"'"#,
        #"-c "'otel'.log_user_prompt=false""#,
    ])
    func explicitConfig(arguments: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.run(defaults: defaults, command: "__ctrlx_install_codex_telemetry; codex \(arguments)")
        #expect(result.isSuccess)
        #expect(!result.stdoutString.contains("54321"))
        #expect(result.stdoutString.contains("otel"))
    }

    @Test("UI-supplied defaults appear exactly once")
    func noDuplicateArguments() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let quoted = defaults.map(\.posixSingleQuoted).joined(separator: " ")
        let result = try await fixture.run(defaults: defaults, command: "__ctrlx_install_codex_telemetry; codex \(quoted)")
        #expect(result.isSuccess)
        #expect(result.stdoutString.components(separatedBy: "54321").count == 2)
        #expect(result.stdoutString.components(separatedBy: "<-c>").count == 3)
    }

    @Test("Fork config overrides survive rc, preserve shell commands/telemetry and do not leak into the prompt", arguments: [
        "",
        "alias codex='command codex'",
        "function codex() { command codex \"$@\"; }",
    ])
    func forkEnvironment(rc: String) async throws {
        let fixture = try Fixture(extraRC: "export CODEX_HOME='/wrong root'\n\(rc)")
        defer { fixture.cleanup() }
        let root = #"/chosen 'root'; $(touch SHOULD_NOT_EXIST)"#
        let prepared = SessionLaunchPreparation(workingDirectory: fixture.root.path, fork: AgentForkLaunch(
            command: LaunchCommand(command: "codex", args: ["fork", "exact-session"], env: ["CODEX_HOME": root, "CODEX_FIXTURE_EXIT": "37"])
        ))
        let tmux = try FakeTmuxLaunchEnvironment()
        defer { tmux.cleanup() }
        let launch = try #require(try prepared.agentLaunch(shell: "/bin/zsh", tmuxExecutable: tmux.executable.path))
        try tmux.install(launch)
        #expect(!launch.command.contains(root))
        let result = try await fixture.run(defaults: defaults, command: """
        __ctrlx_install_codex_telemetry
        \(launch.command)
        print -r -- "FORK_EXIT=$?"
        print -r -- "AFTER_ROOT=$CODEX_HOME"
        """, environment: ["TMUX": "fixture,1,0", "TMUX_PANE": FakeTmuxLaunchEnvironment.pane])
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("CONFIG_ROOT[\(root)]"))
        #expect(result.stdoutString.contains("<fork>\n<exact-session>"))
        #expect(result.stdoutString.contains("FORK_EXIT=37"))
        #expect(result.stdoutString.contains("AFTER_ROOT=/wrong root"))
        #expect(result.stdoutString.components(separatedBy: "54321").count == (rc.isEmpty ? 2 : 1))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        #expect(!tmux.containsPayload())
    }

    @Test("Ordinary launch reapplies Provider environment after rc and removes it from the running shell")
    func ordinaryProviderEnvironment() async throws {
        let fixture = try Fixture(extraRC: """
        export ANTHROPIC_API_KEY='wrong-key'
        export ANTHROPIC_AUTH_TOKEN='wrong-token'
        export ANTHROPIC_BASE_URL='https://wrong.example.com'
        export ANTHROPIC_MODEL='wrong-model'
        export CTRLX_AGENT_PROVIDER_ID='wrong-provider'
        """)
        defer { fixture.cleanup() }
        let prepared = SessionLaunchPreparation(workingDirectory: fixture.root.path, launch: LaunchCommand(
            command: "codex",
            args: ["--version"],
            env: [
                "ANTHROPIC_API_KEY": "selected-key",
                "ANTHROPIC_BASE_URL": "https://selected.example.com",
                "ANTHROPIC_MODEL": "selected-model",
                "CTRLX_AGENT_PROVIDER_ID": "selected-provider",
            ],
            unsetEnvironment: ["ANTHROPIC_AUTH_TOKEN"]
        ))
        let tmux = try FakeTmuxLaunchEnvironment()
        defer { tmux.cleanup() }
        let launch = try #require(try prepared.agentLaunch(shell: "/bin/zsh", tmuxExecutable: tmux.executable.path))
        try tmux.install(launch)
        #expect(!launch.command.contains("selected-key"))
        let result = try await fixture.run(defaults: nil, command: """
        \(launch.command)
        print -r -- "AGENT_EXIT=$?"
        print -r -- "AFTER_KEY=$ANTHROPIC_API_KEY"
        print -r -- "AFTER_TOKEN=$ANTHROPIC_AUTH_TOKEN"
        print -r -- "AFTER_URL=$ANTHROPIC_BASE_URL"
        print -r -- "AFTER_MODEL=$ANTHROPIC_MODEL"
        print -r -- "AFTER_PROVIDER=$CTRLX_AGENT_PROVIDER_ID"
        """, environment: ["TMUX": "fixture,1,0", "TMUX_PANE": FakeTmuxLaunchEnvironment.pane])
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("AGENT_KEY[selected-key]"))
        #expect(result.stdoutString.contains("AGENT_TOKEN_SET[]"))
        #expect(result.stdoutString.contains("AGENT_URL[https://selected.example.com]"))
        #expect(result.stdoutString.contains("AGENT_MODEL[selected-model]"))
        #expect(result.stdoutString.contains("AGENT_PROVIDER[selected-provider]"))
        #expect(result.stdoutString.contains("AFTER_KEY=wrong-key"))
        #expect(result.stdoutString.contains("AFTER_TOKEN=wrong-token"))
        #expect(result.stdoutString.contains("AFTER_URL=https://wrong.example.com"))
        #expect(result.stdoutString.contains("AFTER_MODEL=wrong-model"))
        #expect(result.stdoutString.contains("AFTER_PROVIDER=wrong-provider"))
        #expect(!tmux.containsPayload())
    }

    @Test("Default Claude Fork unsets inherited config only for the Agent")
    func forkDefaultClaudeEnvironment() async throws {
        let fixture = try Fixture(extraRC: """
        export CLAUDE_CONFIG_DIR='/wrong claude root'
        function claude() { print -r -- "CLAUDE_CONFIG_SET=${+CLAUDE_CONFIG_DIR}"; }
        """)
        defer { fixture.cleanup() }
        let prepared = SessionLaunchPreparation(workingDirectory: fixture.root.path, fork: AgentForkLaunch(
            command: LaunchCommand(command: "claude", args: ["--resume", "exact-session", "--fork-session"]),
            unsetEnvironment: ["CLAUDE_CONFIG_DIR"]
        ))
        let tmux = try FakeTmuxLaunchEnvironment()
        defer { tmux.cleanup() }
        let launch = try #require(try prepared.agentLaunch(shell: "/bin/zsh", tmuxExecutable: tmux.executable.path))
        try tmux.install(launch)
        let result = try await fixture.run(defaults: defaults, command: """
        \(launch.command)
        print -r -- "AFTER_CLAUDE_ROOT=$CLAUDE_CONFIG_DIR"
        """, environment: ["TMUX": "fixture,1,0", "TMUX_PANE": FakeTmuxLaunchEnvironment.pane])
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("CLAUDE_CONFIG_SET=0"))
        #expect(result.stdoutString.contains("AFTER_CLAUDE_ROOT=/wrong claude root"))
    }

    @Test("Recovery keeps the Agent payload out of process arguments")
    @MainActor
    func recoveryEnvironment() throws {
        let secret = "fixture-secret-value"
        let prepared = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(
            command: LaunchCommand(command: "codex", env: ["CODEX_API_KEY": secret])
        ))
        let launch = try #require(try prepared.agentLaunch(shell: "/bin/zsh", tmuxExecutable: "/fixture/tmux"))
        let process = TmuxService.recoveryProcess(
            loginShell: "/bin/zsh",
            invocation: launch.command,
            prefix: nil
        )
        #expect(!process.joined(separator: " ").contains(secret))
        #expect(!process.joined(separator: " ").contains(launch.payload ?? ""))
        #expect(process.joined(separator: " ").contains("show-options -pv"))
    }

    @Test("Prompt text after -- is not parsed as config")
    func promptIsNotConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.run(defaults: defaults, command: #"__ctrlx_install_codex_telemetry; codex -- '-c' 'otel.exporter=none'"#)
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("54321"))
        #expect(result.stdoutString.contains("<-->\n<-c>\n<otel.exporter=none>"))
    }

    @Test("User aliases and functions win", arguments: [
        "alias codex='print USER_ALIAS'",
        "function codex() { print USER_FUNCTION; }",
    ])
    func userCommands(rc: String) async throws {
        let fixture = try Fixture(extraRC: rc)
        defer { fixture.cleanup() }
        // Separate parse units: the alias must expand after initialization.
        let result = try await fixture.run(defaults: defaults, command: "__ctrlx_install_codex_telemetry\ncodex hello")
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("USER_"))
        #expect(!result.stdoutString.contains("54321"))
    }

    @Test("Absolute executable and command codex deliberately bypass the function")
    func bypass() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let result = try await fixture.run(defaults: defaults, command: """
        __ctrlx_install_codex_telemetry
        \(fixture.executable.path.posixSingleQuoted) --version
        command codex --help
        """)
        #expect(result.isSuccess)
        #expect(!result.stdoutString.contains("54321"))
        #expect(result.stdoutString.contains("<--version>"))
        #expect(result.stdoutString.contains("<--help>"))
    }

    @Test("Noninteractive and ordinary outside shells are not instrumented")
    func noOutsideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let noninteractive = try await fixture.run(defaults: defaults, command: "print ${+functions[codex]}", interactive: false)
        #expect(noninteractive.isSuccess)
        #expect(noninteractive.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        let outside = try await fixture.run(defaults: nil, command: "codex test")
        #expect(outside.isSuccess)
        #expect(outside.stdoutString.contains("<test>"))
        #expect(!outside.stdoutString.contains("54321"))
    }

    @Test("Initialization arguments are shell-quoted, never evaluated")
    func escapedDefaults() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let value = #"argument with 'single quotes', "double quotes"; $(touch SHOULD_NOT_EXIST)"#
        let result = try await fixture.run(defaults: [value], command: "__ctrlx_install_codex_telemetry; codex hello")
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("<\(value)>"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    @Test("Startup files are private, reused for equal content and isolated across settings")
    func fileStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = TerminalAgentShellFileStore(root: fixture.root.appendingPathComponent("store"))
        let first = try await store.prepare(defaults)
        #expect(try await store.prepare(defaults) == first)
        #expect(try await store.prepare(["-c", "otel.exporter=none"]) != first)
        let attributes = try FileManager.default.attributesOfItem(atPath: first + "/.zshenv")
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Isolated tmux: local/iOS/Viewer New Terminal instruments plain codex, not the existing pane", arguments: [false, true])
    @MainActor
    func liveNewTerminal(viewerRequest: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let binary = try #require(TmuxBinaryLocator.liveValue.find())
        let socket = fixture.root.appendingPathComponent("tmux.sock").path
        let runner = ProcessRunner.liveValue
        let store = TerminalAgentShellFileStore(root: fixture.root.appendingPathComponent("live-init"))
        do {
            try await withDependencies {
                $0[ProcessRunner.self] = runner
                $0[TerminalAgentShellFiles.self].prepare = { try await store.prepare($0) }
                $0.continuousClock = ContinuousClock()
            } operation: {
                let tmux = TmuxService(tmuxPath: binary, socketPath: socket)
                tmux.zdotDirOverride = fixture.dotfiles.path
                let original = try await tmux.createSession(baseName: "shell-test", width: 200, height: 32)
                tmux.terminalCodexArguments = { defaults }
                let pane = if viewerRequest {
                    // The same Host handler used by iOS and Mac Viewer. No
                    // agent ID, exporter endpoint or startup keystrokes in the request.
                    try await TmuxWindowCreation.create(
                        CreateTmuxWindow(sessionName: original.sessionName, workingDirectory: fixture.root.path),
                        core: nil, tmux: tmux
                    )
                } else {
                    try await tmux.newWindow(sessionName: original.sessionName, workingDirectory: fixture.root.path)
                }
                for _ in 0..<30 {
                    if try await tmux.capturePaneText(pane).contains("TEST_READY>") {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                // Send only to our temporary fixture pane after its first prompt.
                _ = try await runner.run(binary, ["-S", socket, "send-keys", "-t", pane, "codex resume --last", "Enter"], nil, nil)
                var screen = ""
                for _ in 0..<30 {
                    screen = try await tmux.capturePaneText(pane)
                    if screen.contains("<--last>") {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(screen.contains("<\(defaults[1])>"))
                #expect(screen.contains("<resume>"))
                #expect(screen.contains("<--last>"))
                let originalScreen = try await tmux.capturePaneText(original.paneId)
                #expect(!originalScreen.contains("54321"))
            }
        } catch {
            _ = try? await runner.run(binary, ["-S", socket, "kill-server"], nil, nil)
            throw error
        }
        let cleanup = try await runner.run(binary, ["-S", socket, "kill-server"], nil, nil)
        #expect(cleanup.isSuccess)
    }

    @Test("New shells use current arguments; explicit split commands and disabled telemetry are untouched")
    @MainActor
    func tmuxWiring() async throws {
        let calls = LockIsolated<[[String]]>([])
        let prepared = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0[TerminalAgentShellFiles.self].prepare = { args in
                prepared.withValue { $0.append(args) }
                return "/temporary/init dir"
            }
            $0[ProcessRunner.self].run = { _, args, _, _ in
                calls.withValue { $0.append(args) }
                return Self.tmuxResult(for: args)
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/fixture/tmux")
            tmux.terminalCodexArguments = { defaults }
            _ = try await tmux.createSession(baseName: "fixture", width: 80, height: 24)
            _ = try await tmux.newWindow(sessionName: "fixture", windowName: "terminal")
            _ = try await tmux.splitPane("%1", horizontal: true)
            _ = try await tmux.splitPane("%1", horizontal: false, shellCommand: "custom-shell --flag")
            tmux.terminalCodexArguments = { [] }
            _ = try await tmux.newWindow(sessionName: "fixture", windowName: "uninstrumented")
        }
        #expect(prepared.value == [defaults, defaults, defaults])
        #expect(calls.value.filter { $0.last?.contains("CTRLX_SHELL_ORIGINAL_ZDOTDIR") == true }.count == 3)
        #expect(calls.value.contains { $0.last == "custom-shell --flag" })
        #expect(!calls.value.contains { $0.contains { $0 == "send-keys" || $0.hasPrefix("'send-keys' ") } })
    }

    @Test("Failed startup-file preparation does not block New Terminal")
    @MainActor
    func preparationFailure() async throws {
        let calls = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0[TerminalAgentShellFiles.self].prepare = { _ in throw CocoaError(.fileWriteOutOfSpace) }
            $0[ProcessRunner.self].run = { _, args, _, _ in
                calls.withValue { $0.append(args) }
                return Self.tmuxResult(for: args)
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/fixture/tmux")
            tmux.terminalCodexArguments = { defaults }
            let pane = try await tmux.newWindow(sessionName: "fixture", windowName: "terminal")
            #expect(pane == "%42")
        }
        #expect(!calls.value.contains {
            $0.contains { $0 == "send-keys" || $0.hasPrefix("'send-keys' ") }
                || $0.last?.contains("CTRLX_SHELL_ORIGINAL_ZDOTDIR") == true
        })
    }

    @Test("Fork explicitly execs the validated shell with telemetry on, off or unavailable", arguments: ["enabled", "disabled", "unavailable"])
    @MainActor
    func forkShellWiring(telemetry: String) async throws {
        let calls = LockIsolated<[[String]]>([])
        let inputs = LockIsolated<[String]>([])
        try await withDependencies {
            $0[TerminalAgentShellFiles.self].prepare = { _ in
                if telemetry == "unavailable" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                return "/temporary/init dir"
            }
            $0[ProcessRunner.self].run = { _, args, _, _ in
                calls.withValue { $0.append(args) }
                return Self.tmuxResult(for: args)
            }
            $0[ProcessRunner.self].runWithInput = { _, args, _, _, input in
                calls.withValue { $0.append(args) }
                inputs.withValue { $0.append(String(decoding: input, as: UTF8.self)) }
                return Self.tmuxResult(for: args)
            }
        } operation: {
            let tmux = TmuxService(tmuxPath: "/fixture/tmux")
            tmux.terminalCodexArguments = { telemetry == "disabled" ? [] : defaults }
            let prepared = SessionLaunchPreparation(workingDirectory: "/repo", fork: AgentForkLaunch(
                command: LaunchCommand(command: "codex", args: ["fork", "exact-session"], env: ["CODEX_HOME": "/fork root"])
            ))
            let agentLaunch = try #require(try tmux.agentLaunch(prepared))
            _ = try await tmux.newWindow(
                sessionName: "fixture", windowName: "fork", runCommand: agentLaunch.command,
                launchPayload: agentLaunch.payload,
                forceLoginShell: true
            )
            let creation = try #require(calls.value.first { $0.contains("new-window") })
            let shellIndex = try #require(creation.firstIndex(of: "/bin/sh"))
            #expect(Array(creation[shellIndex...].prefix(2)) == ["/bin/sh", "-c"])
            let startup = creation[shellIndex + 2]
            #expect(startup.contains("exec \(tmux.loginShellPath.posixSingleQuoted) -l"))
            #expect(startup.contains("TERM_PROGRAM=iTerm.app"))
            #expect(startup.contains("CTRLX_SHELL_ORIGINAL_ZDOTDIR") == (telemetry == "enabled"))
            #expect(!creation.contains { $0.hasPrefix("CODEX_HOME=") })
            #expect(!creation.contains("/fork root"))
            #expect(inputs.value.count == 1)
            #expect(inputs.value[0].contains("set-option"))
            #expect(inputs.value[0].contains(agentLaunch.payload ?? "missing payload"))
            #expect(!inputs.value[0].contains("/fork root"))
            let input = try #require(calls.value.first { $0.contains { $0.hasPrefix("'send-keys' ") } })
            #expect(input.contains("if-shell"))
            #expect(input.contains("#{==:#{pid}:#{start_time},123:456}"))
            #expect(input.contains("%42"))
            #expect(input.contains { $0.contains("show-options -pv") })
            #expect(input.contains { $0.contains("set-option -pu") })
            #expect(!input.contains { $0.contains("/fork root") })
        }
    }

    private static func tmuxResult(for arguments: [String]) -> ProcessResult {
        let output: String
        if arguments.contains("new-session") || arguments.contains("new-window") {
            output = "123:456\u{1f}%42\n"
        } else if arguments.contains("split-window") {
            output = "%42\n"
        } else {
            output = ""
        }
        return ProcessResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
    }

    /// Real zsh and a harmless fake Codex executable; no agent/network calls or
    /// writes to the user's rc/config/history. A custom ZDOTDIR also proves we
    /// preserve the repository E2E harness's history-isolation directory.
    private struct Fixture {
        let root: URL
        let dotfiles: URL
        let executable: URL

        init(extraRC: String = "") throws {
            let files = FileManager.default
            // Darwin's sockaddr_un has a 104-byte path limit, including the
            // long per-user temporary prefix. Leave room for tmux.sock.
            self.root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cx-sh-\(UUID().uuidString.prefix(8))")
            self.dotfiles = root.appendingPathComponent("user 'dot files'")
            let bin = root.appendingPathComponent("bin")
            self.executable = bin.appendingPathComponent("codex")
            try files.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            for (name, marker) in [(".zshenv", "env"), (".zprofile", "profile"), (".zshrc", "rc"), (".zlogin", "login")] {
                var script = "RC_ORDER+=\(marker),\n"
                if name == ".zshrc" {
                    script += """
                    export PATH=\(bin.path.posixSingleQuoted):/usr/bin:/bin
                    HISTFILE=/dev/null
                    SAVEHIST=0
                    PROMPT='TEST_READY> '
                    function user_prompt_hook() { :; }
                    precmd_functions+=(user_prompt_hook)
                    \(extraRC)

                    """
                }
                try Data(script.utf8).write(to: dotfiles.appendingPathComponent(name))
            }
            try Data("""
            #!/bin/sh
            printf 'CONFIG_ROOT[%s]\\n' "$CODEX_HOME"
            printf 'AGENT_KEY[%s]\\n' "${ANTHROPIC_API_KEY-}"
            printf 'AGENT_TOKEN_SET[%s]\\n' "${ANTHROPIC_AUTH_TOKEN:+set}"
            printf 'AGENT_URL[%s]\\n' "${ANTHROPIC_BASE_URL-}"
            printf 'AGENT_MODEL[%s]\\n' "${ANTHROPIC_MODEL-}"
            printf 'AGENT_PROVIDER[%s]\\n' "${CTRLX_AGENT_PROVIDER_ID-}"
            printf '<%s>\\n' "$@"
            exit "${CODEX_FIXTURE_EXIT:-0}"
            """.utf8).write(to: executable)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func run(
            defaults: [String]?,
            command: String,
            interactive: Bool = true,
            environment: [String: String] = [:]
        ) async throws -> ProcessResult {
            let prefix: String
            if let defaults {
                let directory = try await TerminalAgentShellFileStore(root: root.appendingPathComponent("generated")).prepare(defaults)
                prefix = TerminalAgentShellIntegration.launchPrefix(directory: directory)
            } else {
                prefix = ""
            }
            var environment = environment
            environment["ZDOTDIR"] = dotfiles.path
            environment["RC_ORDER"] = ""
            return try await ProcessRunner.liveValue.run(
                "/bin/sh", ["-c", "cd \(root.path.posixSingleQuoted) && \(prefix)exec /bin/zsh \(interactive ? "-ilc" : "-lc") \(command.posixSingleQuoted)"],
                environment, nil
            )
        }
    }
}
