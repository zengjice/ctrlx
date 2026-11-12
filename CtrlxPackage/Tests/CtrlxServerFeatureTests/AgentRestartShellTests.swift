import CtrlxCommon
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRestartShellTests {
    @Test("Resume reloads edited shell files before applying scoped Provider settings", arguments: ["/bin/bash", "/bin/zsh"], [false, true])
    func reloadEnvironment(shell: String, provider: Bool) async throws {
        let tmux = try FakeTmuxLaunchEnvironment()
        defer { tmux.cleanup() }
        let home = tmux.root.appendingPathComponent("home with 'quotes'")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let bash = shell == "/bin/bash"
        let profile = home.appendingPathComponent(bash ? ".bash_profile" : ".zprofile")
        let rc = home.appendingPathComponent(bash ? ".bashrc" : ".zshrc")
        let profileConfiguration = (bash ? ". \"$HOME/.bashrc\"\n" : "") + "export CTRLX_RESTART_LOGIN=loaded\n"
        try Data(profileConfiguration.utf8).write(to: profile)
        let preparation = SessionLaunchPreparation(workingDirectory: home.path, fork: AgentForkLaunch(command: .init(
            command: "restart_probe",
            env: provider ? ["CTRLX_RESTART_PROVIDER": "settings"] : [:],
            unsetEnvironment: provider ? ["CTRLX_RESTART_CLEARED"] : []
        )))
        let launch = try #require(try preparation.agentLaunch(shell: shell, tmuxExecutable: tmux.executable.path))
        let process = AgentRestartTerminal.process(
            loginShell: shell, invocation: launch.command, prefix: "export VISUAL=ctrlx-editor",
            shellCommand: #"printf 'FALLBACK[%s]\n' "$CTRLX_RESTART_VALUE""#
        )
        for value in ["old", "fresh"] {
            let configuration = """
            export CTRLX_RESTART_VALUE=\(value)
            export CTRLX_RESTART_PROVIDER=rc
            export CTRLX_RESTART_CLEARED=rc
            export VISUAL=rc-editor
            export PATH="$HOME/fixture-bin:$PATH"
            restart_probe() {
                /bin/sh -c 'printf "VALUE[%s]LOGIN[%s]PROVIDER[%s]CLEARED[%s]VISUAL[%s]PATH[%s]\\n" "$CTRLX_RESTART_VALUE" "$CTRLX_RESTART_LOGIN" "$CTRLX_RESTART_PROVIDER" "${CTRLX_RESTART_CLEARED+x}" "$VISUAL" "${PATH%%:*}"'
                return 37
            }
            """
            try Data(configuration.utf8).write(to: rc, options: .atomic)
            try tmux.install(launch)
            let result = try await run(process, home: home)
            #expect(result.isSuccess)
            #expect(result.stdoutString.contains("VALUE[\(value)]LOGIN[loaded]PROVIDER[\(provider ? "settings" : "rc")]CLEARED[\(provider ? "" : "x")]VISUAL[ctrlx-editor]PATH[\(home.path)/fixture-bin]"))
            #expect(result.stdoutString.contains("FALLBACK[\(value)]"))
            #expect(!tmux.containsPayload())
        }
    }

    @Test("Bash does not source .bashrc when no login profile selects it")
    func bashRCIsNotImplicit() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-restart-bash-rc-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("export CTRLX_RESTART_VALUE=from-rc\nprintf loaded > \"$HOME/rc-loaded\"\n".utf8).write(to: home.appendingPathComponent(".bashrc"))
        let process = AgentRestartTerminal.process(
            loginShell: "/bin/bash", invocation: #"/bin/sh -c 'printf "VALUE[%s]\n" "$CTRLX_RESTART_VALUE"'"#,
            prefix: nil, shellCommand: "true"
        )
        let result = try await run(process, home: home)
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("VALUE[stale]"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("rc-loaded").path))
    }

    @Test("Bash preserves the selected login profile's final environment and never reloads its rc", arguments: [".bash_profile", ".bash_login", ".profile"], [false, true])
    func bashLoginOrder(profile: String, sourcesRC: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-restart-bash-order-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let rc = """
        printf 'rc\\n' >> "$HOME/rc-loads"
        export ANTHROPIC_BASE_URL=https://default.invalid
        """
        try Data(rc.utf8).write(to: home.appendingPathComponent(".bashrc"))
        let profiles = [".bash_profile", ".bash_login", ".profile"]
        for name in profiles.drop(while: { $0 != profile }) {
            let configuration = name == profile
                ? (sourcesRC ? ". \"$HOME/.bashrc\"\n" : "") + "export ANTHROPIC_BASE_URL=https://working.invalid\n"
                : "export ANTHROPIC_BASE_URL=https://ignored.invalid\n"
            try Data(configuration.utf8).write(to: home.appendingPathComponent(name))
        }
        let process = AgentRestartTerminal.process(
            loginShell: "/bin/bash", invocation: #"/bin/sh -c 'printf "ENDPOINT[%s]\n" "$ANTHROPIC_BASE_URL"'"#,
            prefix: nil, shellCommand: "true"
        )
        let result = try await run(process, home: home)
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("ENDPOINT[https://working.invalid]"))
        let loads = home.appendingPathComponent("rc-loads")
        if sourcesRC {
            #expect(try String(contentsOf: loads, encoding: .utf8) == "rc\n")
        } else {
            #expect(!FileManager.default.fileExists(atPath: loads.path))
        }
    }

    @Test("Missing startup files do not block Resume or the shell after a CLI failure", arguments: ["/bin/bash", "/bin/zsh"])
    func missingStartupFiles(shell: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-restart-shell-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = AgentRestartTerminal.process(
            loginShell: shell, invocation: "printf RESUME_ATTEMPTED; /usr/bin/false", prefix: nil,
            shellCommand: "printf FALLBACK_REACHED"
        )
        let result = try await run(process, home: home)
        #expect(result.isSuccess)
        #expect(result.stdoutString.contains("RESUME_ATTEMPTED"))
        #expect(result.stdoutString.contains("FALLBACK_REACHED"))
    }

    private func run(_ process: [String], home: URL) async throws -> ProcessResult {
        try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
            try await ProcessRunner.liveValue.run(
                process[0], Array(process.dropFirst()),
                ["HOME": home.path, "ZDOTDIR": home.path, "TMUX": "fixture,1,0", "TMUX_PANE": FakeTmuxLaunchEnvironment.pane, "CTRLX_RESTART_VALUE": "stale"],
                10
            )
        }
    }
}
