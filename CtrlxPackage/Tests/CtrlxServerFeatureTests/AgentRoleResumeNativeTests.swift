import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentRoleResumeNativeTests {
    @Test(arguments: ["shell", "busy", "changed", "process-race", "identity-race"])
    func originalTerminal(mode: String) async throws {
        let directory = URL(fileURLWithPath: "/tmp/ctrlx-role-resume-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("tmux.sock").path
        let binary = try #require(TmuxBinaryLocator.liveValue.find())
        let runner = ProcessRunner.liveValue
        let environment = ["HOME": directory.path, "ZDOTDIR": directory.path, "TMUX": "", "TMUX_PANE": ""]
        let raceInjected = LockIsolated(false)
        let rejection = LockIsolated<String?>(nil)
        let run: @Sendable ([String]) async throws -> ProcessResult = { arguments in
            try await withDependencies { $0.continuousClock = ContinuousClock() } operation: {
                try await runner.run(executable: binary, arguments: ["-S", socket, "-f", "/dev/null"] + arguments, environment: environment, timeout: 10)
            }
        }
        do {
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
                $0[ProcessRunner.self].run = { path, arguments, supplied, timeout in
                    try await runner.run(executable: path, arguments: arguments, environment: (supplied ?? [:]).merging(environment) { _, isolated in isolated }, timeout: timeout)
                }
                $0[ProcessRunner.self].runWithInput = { path, arguments, supplied, timeout, input in
                    #expect(!arguments.joined().contains("private-provider-value"))
                    let inject = mode.hasSuffix("-race") && !raceInjected.withValue { previous in
                        let old = previous
                        previous = true
                        return old
                    }
                    if inject {
                        let target = try await run(["list-panes", "-a", "-F", "#{pane_id}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                        let change = mode == "process-race"
                            ? ["respawn-pane", "-k", "-t", target, "/bin/zsh", "-f"]
                            : ["set-option", "-p", "-t", target, WorkspaceTmuxRecovery.paneKey, UUID().uuidString]
                        try #require(try await run(change).isSuccess)
                    }
                    let result = try await runner.runWithInput(executable: path, arguments: arguments, environment: (supplied ?? [:]).merging(environment) { _, isolated in isolated }, timeout: timeout, input: input)
                    if inject {
                        rejection.setValue(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    return result
                }
                $0[SessionDirectoryClient.self].resolve = { $0 }
            } operation: {
                let command = mode == "busy" ? ["/bin/sleep", "60"] : ["/bin/zsh", "-f"]
                try #require(try await run(["new-session", "-d", "-s", "fixture", "-c", directory.path] + command).isSuccess)
                let tmux = TmuxService(tmuxPath: binary, socketPath: socket)
                tmux.zdotDirOverride = directory.path
                tmux.workflowInputGate = AgentWorkflowInputGate()
                let pane = try #require(await tmux.refreshPanes().first)
                let identity = try #require(pane.workspaceIdentity)
                let token = UUID()
                let marker = directory.appendingPathComponent("resumed")
                let launch = AgentForkLaunch(command: .init(command: "/bin/sh", args: ["-c", "printf resumed > \(marker.path.posixSingleQuoted); exec /bin/cat"], env: ["CTRLX_ROLE_TEST_VALUE": "private-provider-value"]))
                if mode == "changed" {
                    try #require(try await run(["set-option", "-p", "-t", pane.paneId, WorkspaceTmuxRecovery.paneKey, UUID().uuidString]).isSuccess)
                }
                if mode == "shell" {
                    try await tmux.resumeStoppedRole(pane, directory: directory.path, command: launch, intentID: token)
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    #expect(try String(contentsOf: marker, encoding: .utf8) == "resumed")
                    let after = await tmux.refreshPanes()
                    #expect(after.count == 1 && after.first?.workspaceIdentity == identity)
                    let saved = try await run(["display-message", "-p", "-t", pane.paneId, "#{\(AgentRoleRecovery.launchTokenOption)}"])
                    #expect(saved.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == token.uuidString)
                    // A repeat while the resumed program runs must leave it alone.
                    await #expect(throws: AgentRoleRecovery.NotLaunched.self) {
                        try await tmux.resumeStoppedRole(pane, directory: directory.path, command: launch, intentID: UUID())
                    }
                } else if mode.hasSuffix("-race") {
                    let id = AgentID(hostID: UUID(), paneID: identity.paneID)
                    let descriptor = AgentResumeDescriptor(pluginID: "codex", sessionID: UUID().uuidString, projectPath: directory.path, configurationRoot: directory.path, usesDefaultConfiguration: true)
                    let recovery = AgentRoleRecovery(file: directory.appendingPathComponent("resume.json"), paneExists: { _ in true }, launch: { _, _ in throw CancellationError() }, locate: { _ in nil }, inspect: { _, _ in nil }, resumeExisting: { intent, _, _ in
                        try await tmux.resumeStoppedRole(pane, directory: directory.path, command: launch, intentID: intent)
                        return identity
                    })
                    try await recovery.capture(id, descriptor: descriptor, invalidated: false)
                    await #expect(throws: AgentWorkflowError.self) { try await recovery.restore(id) }
                    #expect(rejection.value == (mode == "process-race" ? AgentRestartTerminal.rejection : WorkspaceTerminalInputGuard.rejection))
                    #expect(try await recovery.entry(id)?.intent?.attempted == false)
                    #expect(!FileManager.default.fileExists(atPath: marker.path))
                    if mode == "identity-race" {
                        try #require(try await run(["set-option", "-p", "-t", pane.paneId, WorkspaceTmuxRecovery.paneKey, identity.paneID.uuidString]).isSuccess)
                    }
                    // The process may now start; inspection still waits for its native conversation.
                    await #expect(throws: AgentRoleRecovery.Starting.self) { try await recovery.restore(id) }
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    #expect(FileManager.default.fileExists(atPath: marker.path))
                    #expect(try await recovery.entry(id)?.intent?.pane == identity)
                } else {
                    await #expect(throws: AgentRoleRecovery.NotLaunched.self) {
                        try await tmux.resumeStoppedRole(pane, directory: directory.path, command: launch, intentID: token)
                    }
                    #expect(!FileManager.default.fileExists(atPath: marker.path))
                }
            }
        } catch {
            _ = try? await run(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try? await run(["kill-server"])
        try FileManager.default.removeItem(at: directory)
    }
}
