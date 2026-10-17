import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceTerminalInputTests {
    private func withTmux(_ test: (TmuxService, TmuxControlClientManager, @escaping @Sendable ([String]) async throws -> ProcessResult) async throws -> Void) async throws {
        let path = try #require(TmuxBinaryLocator.liveValue.find())
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ctrlx-input-identity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("tmux.sock").path
        let runner = ProcessRunner.liveValue
        let run: @Sendable ([String]) async throws -> ProcessResult = { args in
            try await runner.run(executable: path, arguments: ["-S", socket, "-f", "/dev/null"] + args, environment: ["TMUX": "", "TMUX_PANE": ""], timeout: 10)
        }
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let tmux = TmuxService(tmuxPath: path, socketPath: socket)
            tmux.zdotDirOverride = directory.path
            let manager = TmuxControlClientManager(tmuxPath: path, socketPath: socket)
            do {
                try await test(tmux, manager, run)
            } catch {
                await manager.disconnectAll()
                _ = try? await run(["kill-server"])
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            await manager.disconnectAll()
            _ = try? await run(["kill-server"])
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func setup(_ run: @Sendable ([String]) async throws -> ProcessResult, paneID: UUID) async throws -> WorkspacePaneIdentity {
        let created = try await run(["new-session", "-d", "-s", "input", "-x", "120", "-y", "30", "/bin/cat"])
        #expect(created.isSuccess)
        let server = try await run(["display-message", "-p", "-t", "%0", "#{pid}:#{start_time}"])
        _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, paneID.uuidString])
        let identity = WorkspacePaneIdentity(serverID: server.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), sessionID: UUID(), windowID: UUID(), paneID: paneID)
        _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, identity.windowID.uuidString])
        _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, identity.sessionID.uuidString])
        return identity
    }

    @Test("A close confirmation cannot adopt reconstructed targets even when every persistent UUID is reused", arguments: WorkspaceRecoveryCloseRequest.Kind.allCases, [false, true])
    func confirmedClose(kind: WorkspaceRecoveryCloseRequest.Kind, journalEnabled: Bool) async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            _ = try await run(["kill-server"])
            let created = try await setup(run, paneID: original.paneID)
            var restored = original
            restored.serverID = created.serverID
            _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, restored.sessionID.uuidString])
            _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, restored.windowID.uuidString])
            var closes: [WorkspaceRecoveryClosedTarget] = []
            var requested = false
            if journalEnabled {
                tmux.workspaceCloseHandler = { operation in
                    requested = true
                    if let target = try await operation() {
                        closes.append(target)
                    }
                }
            }
            func close(_ identity: WorkspacePaneIdentity) async throws {
                switch kind {
                case .session: try await tmux.killSession("input", expectedWorkspacePane: identity)
                case .window: try await tmux.killWindow("@0", expectedWorkspacePane: identity)
                case .pane: try await tmux.killPane("%0", expectedWorkspacePane: identity)
                }
            }
            let pid = try await run(["display-message", "-p", "-t", "%0", "#{pane_pid}"]).stdoutString
            await #expect(throws: WorkspaceRecoveryError.self) { try await close(original) }
            var replacement = restored
            switch kind {
            case .session: replacement.sessionID = UUID()
            case .window: replacement.windowID = UUID()
            case .pane: replacement.paneID = UUID()
            }
            await #expect(throws: WorkspaceRecoveryError.self) { try await close(replacement) }
            #expect(!requested && closes.isEmpty)
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{pane_pid}"]).stdoutString == pid)
            try await close(restored)
            #expect(try await !run(["has-session", "-t", "input"]).isSuccess)
            let expected: WorkspaceRecoveryClosedTarget = switch kind {
            case .session: .session(restored.sessionID)
            case .window: .window(restored.windowID)
            case .pane: .pane(restored.paneID)
            }
            #expect(closes == (journalEnabled ? [expected] : []))
        }
    }

    @Test("Fit, split and selection reject recycled targets and accept current identities")
    func nonInputCommands() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            _ = try await run(["kill-server"])
            let fresh = try await setup(run, paneID: original.paneID)
            _ = try await run(["new-window", "-t", "input", "-n", "other", "/bin/cat"])
            let executor = TmuxCommandExecutor(tmuxService: tmux)
            for (target, command) in [
                ("%0", SplitTmuxPane(direction: .horizontal).commandType),
                ("%0", SelectTmuxPane().commandType),
                ("input:0", SelectTmuxWindow().commandType),
                ("@0", ResizeTmuxPane(width: 100, height: 26, userInitiated: true).commandType),
            ] {
                let response = await executor.execute(.init(paneId: target, command: command, expectedWorkspacePane: original))
                #expect(!response.success)
            }
            let unchanged = try await run(["display-message", "-p", "-t", "@0", "#{window_width}:#{window_height}:#{window_panes}:#{window_active}"])
            #expect(unchanged.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "120:30:1:0")
            try await tmux.fitWindow("@0", width: 100, height: 26, expectedWorkspacePane: fresh)
            try await tmux.selectWindow("input:0", expectedWorkspacePane: fresh)
            let split = try await tmux.splitPane("%0", horizontal: true, shellCommand: "/bin/cat", expectedWorkspacePane: fresh)
            #expect(split.hasPrefix("%"))
            try await tmux.selectPane("%0", expectedWorkspacePane: fresh)
            let result = try await run(["display-message", "-p", "-t", "%0", "#{window_width}:#{window_height}:#{window_panes}:#{window_active}:#{pane_active}"])
            #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "100:26:2:1:1")
            var wrongWindow = fresh
            wrongWindow.windowID = UUID()
            await #expect(throws: (any Error).self) {
                try await tmux.fitWindow("@0", width: 90, height: 24, expectedWorkspacePane: wrongWindow)
            }
        }
    }

    @Test("Window rename rejects replacement windows and restarted servers without binding to the active pane", arguments: [false, true])
    func windowRename(restart: Bool) async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            var current = original
            if restart {
                _ = try await run(["kill-server"])
                current.serverID = try await setup(run, paneID: original.paneID).serverID
                _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, original.windowID.uuidString])
            } else {
                current.windowID = UUID()
                _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, current.windowID.uuidString])
            }
            let before = try await run(["display-message", "-p", "-t", "@0", "#{window_name}:#{pane_pid}"]).stdoutString
            await #expect(throws: (any Error).self) {
                try await tmux.renameWindow(target: "@0", name: "stale-name", expectedWorkspacePane: original)
            }
            #expect(try await run(["display-message", "-p", "-t", "@0", "#{window_name}:#{pane_pid}"]).stdoutString == before)

            // Replacing a pane inside the same physical window must not retire the window's editor.
            _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, UUID().uuidString])
            let name = "rename 'quote' ; 中文"
            try await tmux.renameWindow(target: "@0", name: name, expectedWorkspacePane: current)
            #expect(try await run(["display-message", "-p", "-t", "@0", "#{window_name}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == name)
            try await tmux.renameWindow(target: "input:0", name: "legacy")
            #expect(try await run(["display-message", "-p", "-t", "@0", "#{window_name}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "legacy")
        }
    }

    @Test("Session rename rejects replacement sessions and restarted servers, independently of child identity", arguments: [false, true])
    func sessionRename(restart: Bool) async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            var current = original
            if restart {
                _ = try await run(["kill-server"])
                current.serverID = try await setup(run, paneID: original.paneID).serverID
                _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, original.sessionID.uuidString])
            } else {
                current.sessionID = UUID()
                _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, current.sessionID.uuidString])
            }
            let before = try await run(["display-message", "-p", "-t", "%0", "#{session_name}:#{pane_pid}"]).stdoutString
            await #expect(throws: (any Error).self) {
                try await tmux.renameSession(from: "input", to: "stale-name", expectedWorkspacePane: original)
            }
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{session_name}:#{pane_pid}"]).stdoutString == before)

            // Adding or replacing children does not invalidate the session's editor.
            _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, UUID().uuidString])
            _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, UUID().uuidString])
            let name = "rename 'quote' ; 中文"
            try await tmux.renameSession(from: "input", to: name, expectedWorkspacePane: current)
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{session_name}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == name)
            try await tmux.renameSession(from: name, to: "legacy")
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{session_name}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "legacy")
        }
    }

    @Test("Session metadata preserves replacement sessions and applies uniformly to a live session", arguments: ["description", "color", "emoji"], [false, true])
    func sessionMetadata(field: String, restart: Bool) async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            var current = original
            if restart {
                _ = try await run(["kill-server"])
                current.serverID = try await setup(run, paneID: original.paneID).serverID
            } else {
                current.sessionID = UUID()
            }
            _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, current.sessionID.uuidString])
            let key = "@ctrlx-" + field
            _ = try await run(["set-option", "-t", "input", key, "original"])
            _ = try await run(["set-option", "-w", "-t", "@0", key, "window-override"])
            let pid = try await run(["display-message", "-p", "-t", "%0", "#{pane_pid}"]).stdoutString
            func set(_ identity: WorkspacePaneIdentity?, clear: Bool = false) async throws {
                switch field {
                case "description": try await tmux.setSessionDescription(clear ? nil : "中文 'quoted' ; description", for: "input", expectedWorkspacePane: identity)
                case "color": try await tmux.setSessionColor(clear ? nil : .blue, for: "input", expectedWorkspacePane: identity)
                default: try await tmux.setSessionEmoji(clear ? nil : "🌿", for: "input", expectedWorkspacePane: identity)
                }
            }
            await #expect(throws: (any Error).self) { try await set(original) }
            #expect(try await run(["show-option", "-qv", "-t", "input", key]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "original")
            #expect(try await run(["show-option", "-wqv", "-t", "@0", key]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "window-override")

            _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, UUID().uuidString])
            _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, UUID().uuidString])
            try await set(current)
            let expected = field == "description" ? "中文 'quoted' ; description" : field == "color" ? "blue" : "🌿"
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{\(key)}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
            #expect(try await run(["show-option", "-wqv", "-t", "@0", key]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try await set(current, clear: true)
            #expect(try await run(["show-option", "-qv", "-t", "input", key]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try await set(nil)
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{pane_pid}"]).stdoutString == pid)
        }
    }

    @Test("Metadata writes recheck the server after listing window overrides")
    func sessionMetadataReadRace() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            let swapped = LockIsolated(false)
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    let result = try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    if
                        arguments.joined(separator: " ").contains("list-windows"), !swapped.withValue({ value in
                            let previous = value
                            value = true
                            return previous
                        }) {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                        _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, original.sessionID.uuidString])
                        _ = try await run(["set-option", "-w", "-t", "@0", "@ctrlx-description", "replacement"])
                    }
                    return result
                }
            } operation: {
                await #expect(throws: (any Error).self) {
                    try await tmux.setSessionDescription("stale", for: "input", expectedWorkspacePane: original)
                }
            }
            #expect(swapped.value)
            #expect(try await run(["show-option", "-wqv", "-t", "@0", "@ctrlx-description"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "replacement")
            #expect(try await run(["show-option", "-qv", "-t", "input", "@ctrlx-description"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("Window creation retains its session through asynchronous shell preparation", arguments: [false, true])
    func windowCreationPreparation(restart: Bool) async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            _ = await tmux.refreshPanes()
            tmux.terminalCodexArguments = {
                do {
                    if restart {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                    }
                    let sessionID = restart ? original.sessionID : UUID()
                    _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, sessionID.uuidString])
                } catch { Issue.record(error) }
                return []
            }
            await #expect(throws: TmuxError.self) {
                _ = try await tmux.newWindow(sessionName: "input", runCommand: "must-not-launch")
            }
            #expect(try await run(["list-windows", "-t", "input", "-F", "#{window_id}"]).stdoutString == "@0\n")
            tmux.terminalCodexArguments = { [] }
            let fresh = try #require(await tmux.refreshPanes().first?.workspaceIdentity)
            let paneID = try await tmux.newWindow(sessionName: "input", expectedWorkspacePane: fresh)
            #expect(paneID == "%1")
            #expect(try await run(["display-message", "-p", "-t", paneID, "#{window_name}"]).stdoutString == "terminal 1\n")
        }
    }

    @Test("Agent preparation cannot create a window in a replaced session")
    func agentWindowPreparation() async throws {
        try await withTmux { tmux, _, run in
            _ = try await setup(run, paneID: UUID())
            _ = await tmux.refreshPanes()
            let core = SessionLaunchTestCore(launch: .init(command: "must-not-launch"))
            try await withDependencies {
                $0[SessionDirectoryClient.self].resolve = { path in
                    _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, UUID().uuidString])
                    return path
                }
            } operation: {
                await #expect(throws: TmuxError.self) {
                    _ = try await TmuxWindowCreation.create(.init(sessionName: "input", workingDirectory: "/tmp", pluginID: "codex"), core: core, tmux: tmux)
                }
            }
            #expect(await core.paths == ["/tmp"])
            #expect(try await run(["list-windows", "-t", "input", "-F", "#{window_id}"]).stdoutString == "@0\n")
        }
    }

    @Test("Fork creation checks its source pane as well as the parent session after shell preparation")
    func forkCreationSourceIdentity() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            _ = await tmux.refreshPanes()
            _ = try await run(["set-option", "-g", "default-command", "/bin/cat"])
            let replacementID = UUID()
            tmux.terminalCodexArguments = {
                do {
                    _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, replacementID.uuidString])
                } catch { Issue.record(error) }
                return []
            }
            await #expect(throws: TmuxError.self) {
                _ = try await tmux.newWindow(
                    sessionName: "input",
                    windowName: "fork",
                    runCommand: "must-not-launch",
                    expectedWorkspacePane: original,
                    expectedSourcePaneID: "%0"
                )
            }
            #expect(try await run(["list-windows", "-t", "input", "-F", "#{window_id}"]).stdoutString == "@0\n")
            #expect(try await run(["capture-pane", "-p", "-t", "%0"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            tmux.terminalCodexArguments = { [] }
            let fresh = try #require(await tmux.refreshPanes().first?.workspaceIdentity)
            #expect(fresh.sessionID == original.sessionID && fresh.paneID == replacementID)
            let paneID = try await tmux.newWindow(sessionName: "input", windowName: "fork", expectedWorkspacePane: fresh, expectedSourcePaneID: "%0")
            #expect(paneID == "%1")
        }
    }

    @Test("Post-creation naming and startup cannot target a pane number reused by a new server", arguments: [false, true], [false, true])
    func creationFollowUpIdentity(newSession: Bool, agent: Bool) async throws {
        try await withTmux { tmux, _, run in
            _ = try await setup(run, paneID: UUID())
            let interrupted = LockIsolated(false)
            let replacement = LockIsolated("")
            let format = "#{pane_id}:#{pane_pid}:#{window_name}"
            let creationCommand = newSession ? "new-session" : "new-window"
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    let result = try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    if
                        arguments.joined(separator: " ").contains(creationCommand), !interrupted.withValue({ value in
                            let previous = value
                            value = true
                            return previous
                        }) {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", newSession ? "created" : "input", "-n", "replacement", "/bin/cat"])
                        // Reuse exactly the pane number returned by creation.
                        _ = try await run(["new-window", "-t", newSession ? "created:" : "input:", "-n", "replacement-two", "/bin/cat"])
                        let snapshot = try await run(["list-panes", "-a", "-F", format]).stdoutString
                        replacement.setValue(snapshot)
                    }
                    return result
                }
            } operation: {
                await #expect(throws: TmuxError.self) {
                    if newSession {
                        _ = try await tmux.createSession(baseName: "created", width: 100, height: 30, runCommand: agent ? "must-not-launch" : nil)
                    } else {
                        _ = try await tmux.newWindow(sessionName: "input", windowName: agent ? "agent" : nil, runCommand: agent ? "must-not-launch" : nil)
                    }
                }
            }
            #expect(interrupted.value)
            #expect(try await run(["list-panes", "-a", "-F", format]).stdoutString == replacement.value)
            for paneID in ["%0", "%1"] {
                #expect(try await run(["capture-pane", "-p", "-t", paneID]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @Test("Session creation obtains the actual first pane with nonzero base indexes")
    func creationBaseIndexes() async throws {
        try await withTmux { tmux, _, run in
            _ = try await setup(run, paneID: UUID())
            _ = try await run(["set-option", "-g", "base-index", "7", ";", "set-window-option", "-g", "pane-base-index", "4"])
            let result = try await tmux.createSession(baseName: "created", width: 100, height: 30)
            #expect(result.paneId == "%1")
            #expect(try await run(["display-message", "-p", "-t", result.paneId, "#{pid}:#{start_time}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == result.serverID)
            #expect(try await run(["display-message", "-p", "-t", result.paneId, "#{session_name}:#{window_index}.#{pane_index}"]).stdoutString == "created:7.4\n")
        }
    }

    @Test("Layout apply cannot continue environment or input on a replacement server", arguments: [false, true])
    func layoutApplyContinuation(input: Bool) async throws {
        try await withTmux { tmux, _, run in
            _ = try await setup(run, paneID: UUID())
            if let directory = tmux.zdotDirOverride {
                try "HISTFILE=/dev/null\n".write(toFile: directory + "/.zshrc", atomically: true, encoding: .utf8)
            }
            let marker = "CTRLX_LAYOUT_MUST_NOT_REPLAY"
            let interrupted = LockIsolated(false)
            let config = LayoutConfig(
                sessionName: "layout", startDirectory: "/tmp",
                environment: input ? [:] : [marker: "old"],
                windows: [.init(name: "main", panes: [.init(shellCommands: input ? [marker] : [], enter: false)])]
            )
            let driver = LayoutDriver(
                tmuxAccessor: { tmux }, descriptionApplier: { _, _, _ in },
                colorApplier: { _, _, _ in }, progressApplier: { _, _, _ in }
            )
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    if
                        arguments.joined(separator: " ").contains(marker), !interrupted.withValue({ value in
                            let previous = value
                            value = true
                            return previous
                        }) {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                        _ = try await run(["new-session", "-d", "-s", "layout", "-n", "replacement", "/bin/cat"])
                    }
                    return try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                }
            } operation: {
                await #expect(throws: (any Error).self) { try await driver.apply(config) }
            }
            #expect(interrupted.value)
            let environment = try await run(["show-environment", "-t", "layout", marker])
            #expect(!environment.isSuccess)
            let output = try await run(["capture-pane", "-p", "-t", "%1"]).stdoutString
            #expect(!output.contains(marker))
        }
    }

    @Test("Layout uses actual base indexes and retains identities across window, pane and metadata operations")
    func layoutWithNonzeroIndexes() async throws {
        try await withTmux { tmux, _, run in
            _ = try await setup(run, paneID: UUID())
            _ = try await run(["set-option", "-g", "base-index", "7"])
            _ = try await run(["set-option", "-gw", "pane-base-index", "4"])
            if let directory = tmux.zdotDirOverride {
                try "HISTFILE=/dev/null\n".write(toFile: directory + "/.zshrc", atomically: true, encoding: .utf8)
            }
            let driver = LayoutDriver(
                tmuxAccessor: { tmux },
                descriptionApplier: { value, name, identity in
                    try await tmux.setSessionDescription(value, for: name, expectedWorkspacePane: identity)
                },
                colorApplier: { value, name, identity in
                    try await tmux.setSessionColor(value, for: name, expectedWorkspacePane: identity)
                },
                progressApplier: { _, _, _ in }
            )
            let config = LayoutConfig(
                sessionName: "layout", description: "retained identity", startDirectory: "/tmp",
                environment: ["CTRLX_LAYOUT_VALUE": "live"], options: ["@layout": "session"],
                windows: [
                    .init(name: "first", layout: "even-horizontal", focus: true, options: ["@layout-window": "first"], panes: [
                        .init(shellCommands: ["printf FIRST_LAYOUT"], focus: true),
                        .init(shellCommands: ["printf SECOND_LAYOUT"]),
                    ]),
                    .init(name: "second", panes: [.init(shellCommands: ["printf THIRD_LAYOUT"])]),
                ]
            )
            #expect(try await driver.apply(config).created)
            #expect(try await run(["display-message", "-p", "-t", "layout:", "#{window_index}:#{pane_index}:#{window_panes}"]).stdoutString == "7:4:2\n")
            #expect(try await run(["show-environment", "-t", "layout", "CTRLX_LAYOUT_VALUE"]).stdoutString == "CTRLX_LAYOUT_VALUE=live\n")
            #expect(try await run(["show-option", "-v", "-t", "layout", "@layout"]).stdoutString == "session\n")
            #expect(try await run(["show-option", "-wv", "-t", "layout:7", "@layout-window"]).stdoutString == "first\n")
            #expect(try await run(["list-windows", "-t", "layout", "-F", "#{window_name}"]).stdoutString == "first\nsecond\n")
            #expect(try await run(["display-message", "-p", "-t", "input:0", "#{window_panes}"]).stdoutString == "1\n")
            #expect(try await !driver.apply(config).created)
        }
    }

    @Test("A warm layout hook stops subsequent hooks when its original session disappears")
    func warmLayoutHookRestart() async throws {
        try await withTmux { tmux, _, run in
            _ = try await setup(run, paneID: UUID())
            let hooks = LockIsolated<[String]>([])
            var runner = ProcessRunner.liveValue
            runner.run = { _, arguments, _, _ in
                hooks.withValue { $0.append(arguments.last ?? "") }
                _ = try await run(["kill-server"])
                _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            let driver = LayoutDriver(
                tmuxAccessor: { tmux }, descriptionApplier: { _, _, _ in },
                colorApplier: { _, _, _ in }, progressApplier: { _, _, _ in }, processRunner: runner
            )
            let config = LayoutConfig(sessionName: "input", onApply: [.init(cmd: "first"), .init(cmd: "must-not-run")])
            await #expect(throws: (any Error).self) { try await driver.apply(config, detach: true) }
            #expect(hooks.value == ["first"])
        }
    }

    @Test("CLI resolves exact targets without redirecting a missing explicit pane")
    func cliTargetResolution() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            let pane = try await AppCoordinator.resolvePaneTarget("%0", tmux: tmux)
            #expect(pane.identity == original)
            let session = try await AppCoordinator.resolveSessionTarget(sessionId: "input", paneId: nil, tmux: tmux, method: "test")
            #expect(session.identity == original)
            await #expect(throws: (any Error).self) {
                try await AppCoordinator.resolveSessionTarget(sessionId: "in", paneId: "%0", tmux: tmux, method: "test")
            }
            await #expect(throws: (any Error).self) { try await AppCoordinator.resolvePaneTarget("%999", tmux: tmux) }
            await #expect(throws: (any Error).self) {
                try await AppCoordinator.resolveSessionTarget(sessionId: nil, paneId: "%999", tmux: tmux, method: "test")
            }
            _ = try await run(["kill-server"])
            _ = try await setup(run, paneID: UUID())
            await #expect(throws: (any Error).self) {
                try await tmux.captureWorkspacePane(target: "%0", expectedServerID: original.serverID)
            }
        }
    }

    @Test("A queued window reorder and its rollback never adopt a replacement session", arguments: ["list-windows", "swap-window"], [false, true])
    func windowReorderIdentityRace(checkpoint: String, restart: Bool) async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            for name in ["second", "third"] {
                _ = try await run(["new-window", "-t", "input:", "-n", name, "/bin/cat"])
            }
            let interrupted = LockIsolated(false)
            let replacement = LockIsolated("")
            let format = "#{window_id}:#{window_index}:#{pane_pid}"
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    let result = try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    if
                        arguments.joined(separator: " ").contains(checkpoint), !interrupted.withValue({ value in
                            let previous = value
                            value = true
                            return previous
                        }) {
                        if restart {
                            _ = try await run(["kill-server"])
                            _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                            for name in ["replacement-second", "replacement-third"] {
                                _ = try await run(["new-window", "-t", "input:", "-n", name, "/bin/cat"])
                            }
                        }
                        // Reusing UUIDs after reboot must still reject the old server.
                        let sessionID = restart ? original.sessionID : UUID()
                        _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, sessionID.uuidString])
                        let snapshot = try await run(["list-windows", "-t", "input", "-F", format]).stdoutString
                        replacement.setValue(snapshot)
                    }
                    return result
                }
            } operation: {
                await #expect(throws: (any Error).self) {
                    try await tmux.moveWindows(in: "input", to: ["@2", "@0", "@1"], expectedWorkspacePane: original)
                }
            }
            #expect(interrupted.value)
            #expect(try await run(["list-windows", "-t", "input", "-F", format]).stdoutString == replacement.value)
            let fresh = try #require(await tmux.refreshPanes().first?.workspaceIdentity)
            try await tmux.moveWindows(in: "input", to: ["@1", "@2", "@0"], expectedWorkspacePane: fresh)
            #expect(try await run(["list-windows", "-t", "input", "-F", "#{window_id}"]).stdoutString == "@1\n@2\n@0\n")
        }
    }

    @Test("A partial reorder still rolls back when the original session survives")
    func windowReorderRollback() async throws {
        try await withTmux { tmux, _, run in
            let identity = try await setup(run, paneID: UUID())
            for name in ["second", "third"] {
                _ = try await run(["new-window", "-t", "input:", "-n", name, "/bin/cat"])
            }
            let swaps = LockIsolated(0)
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    if
                        arguments.joined(separator: " ").contains("swap-window"), swaps.withValue({ $0 += 1
                            return $0 }) == 2 {
                        return ProcessResult(exitCode: 1, stdout: Data(), stderr: Data("injected swap failure".utf8))
                    }
                    return try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                }
            } operation: {
                await #expect(throws: (any Error).self) {
                    try await tmux.moveWindows(in: "input", to: ["@2", "@0", "@1"], expectedWorkspacePane: identity)
                }
            }
            #expect(swaps.value > 2)
            #expect(try await run(["list-windows", "-t", "input", "-F", "#{window_id}"]).stdoutString == "@0\n@1\n@2\n")
        }
    }

    @Test("Shared layout rejects old sessions before applying canonical state", arguments: [false, true])
    func sharedLayoutIdentity(restartDuringRead: Bool) async throws {
        try await withTmux { tmux, control, run in
            let original = try await setup(run, paneID: UUID())
            _ = try await run(["new-window", "-t", "input:", "/bin/cat"])
            _ = await tmux.refreshPanes()
            let manager = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[LoginItemService.self] = .previewValue
                $0[LayoutStore.self] = .inMemory()
            } operation: {
                MirrorWindowManager(
                    settings: AppSettings(), tmuxService: tmux,
                    paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: control),
                    editorSessionManager: EditorSessionManager()
                )
            }
            let spec = SetSharedTerminalLayout(sessionName: "input", leftWindowId: "@0", rightWindowIds: ["@1"], selectedRightWindowId: "@1", splitRatio: 0.7)
            func submit(_ identity: WorkspacePaneIdentity?) async -> CommandResponseMessage {
                await AppCoordinator.handleSharedTerminalLayout(
                    command: .init(paneId: "", command: spec.commandType, expectedWorkspacePane: identity), spec: spec,
                    tmuxService: tmux, windowManager: manager, connectionManager: nil
                )
            }
            let intercepted = LockIsolated(false)
            if restartDuringRead {
                try await withDependencies {
                    $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                        let result = try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                        if
                            arguments.contains("if-shell"), !intercepted.withValue({ value in
                                let previous = value
                                value = true
                                return previous
                            }) {
                            _ = try await run(["kill-server"])
                            _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                            _ = try await run(["new-window", "-t", "input:", "/bin/cat"])
                            _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, original.sessionID.uuidString])
                            _ = await tmux.refreshPanes()
                        }
                        return result
                    }
                } operation: {
                    #expect(await !submit(original).success)
                }
                #expect(intercepted.value)
            } else {
                _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, UUID().uuidString])
                #expect(await !submit(original).success)
            }
            #expect(manager.sharedTerminalLayouts.isEmpty)
            let fresh = try #require(await tmux.refreshPanes().first?.workspaceIdentity)
            #expect(await submit(fresh).success)
            #expect(manager.sharedTerminalLayouts["input"]?.rightWindowIds == ["@1"])
            #expect(manager.sharedTerminalLayouts["input"]?.splitRatio == 0.7)
            let revision = manager.sharedTerminalLayouts["input"]?.revision
            #expect(await submit(nil).success)
            #expect(manager.sharedTerminalLayouts["input"]?.revision == revision)
        }
    }

    @Test("Session rename checks again after listing names when tmux restarts")
    func sessionRenameReadRace() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            let swapped = LockIsolated(false)
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    let result = try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    if
                        arguments.contains("list-sessions"), !swapped.withValue({ value in
                            let previous = value
                            value = true
                            return previous
                        }) {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", "input", "/bin/cat"])
                        _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, original.sessionID.uuidString])
                    }
                    return result
                }
            } operation: {
                await #expect(throws: (any Error).self) {
                    try await tmux.renameSession(from: "input", to: "stale-name", expectedWorkspacePane: original)
                }
            }
            #expect(swapped.value)
            #expect(try await run(["display-message", "-p", "-t", "%0", "#{session_name}"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "input")
        }
    }

    @Test("Fit checks again after its layout read when tmux restarts with the same window UUID")
    func fitReadRace() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            let swapped = LockIsolated(false)
            try await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    let result = try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                    if
                        arguments.joined(separator: " ").contains("#{window_layout}"), !swapped.withValue({ value in
                            let wasSwapped = value
                            value = true
                            return wasSwapped
                        }) {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", "input", "-x", "120", "-y", "30", "/bin/cat"])
                        _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, original.windowID.uuidString])
                    }
                    return result
                }
            } operation: {
                await #expect(throws: (any Error).self) {
                    try await tmux.fitWindow("@0", width: 100, height: 26, expectedWorkspacePane: original)
                }
            }
            #expect(swapped.value)
            let dimensions = try await run(["display-message", "-p", "-t", "@0", "#{window_width}:#{window_height}"])
            #expect(dimensions.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "120:30")
        }
    }

    @Test("Image drops reject replaced panes before receipt and immediately before paste", arguments: ["before", "during", "fresh", "legacy"], [false, true])
    func droppedFilesIdentity(phase: String, restartServer: Bool) async throws {
        let filename = "identity-drop-\(UUID()).png"
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        defer {
            // Only remove directories containing this test's unique payload.
            let directories = (try? FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
            for directory in directories where directory.lastPathComponent.hasPrefix("ctrlx-drop-")
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            let replace: @Sendable () async throws -> Void = {
                if restartServer {
                    _ = try await run(["kill-server"])
                    _ = try await run(["new-session", "-d", "-s", "input", "-x", "120", "-y", "30", "/bin/cat"])
                }
                _ = try await run(["set-option", "-t", "input", WorkspaceTmuxRecovery.sessionKey, original.sessionID.uuidString])
                _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, original.windowID.uuidString])
                _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, (restartServer ? original.paneID : UUID()).uuidString])
            }
            if phase == "before" {
                try await replace()
            }
            let intercepted = LockIsolated(false)
            await withDependencies {
                $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                    if
                        phase == "during", arguments.contains(where: { $0.contains("load-buffer") }),
                        !intercepted.withValue({ value in
                            let previous = value
                            value = true
                            return previous
                        }) {
                        try await replace()
                    }
                    return try await ProcessRunner.liveValue.run(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
                }
            } operation: {
                let spec = SendDroppedFiles(files: [.init(name: filename, data: Data([1, 2, 3]))])
                let result = await AppCoordinator.handleSendDroppedFiles(
                    command: .init(paneId: "%0", command: spec.commandType, expectedWorkspacePane: phase == "legacy" ? nil : original),
                    spec: spec, tmuxService: tmux,
                    currentPane: { _ in .init(paneId: "%0", workspaceIdentity: original) }
                )
                #expect(result.success == (phase == "fresh" || phase == "legacy"))
            }
            #expect(intercepted.value == (phase == "during"))
            try await Task.sleep(for: .milliseconds(100))
            let screen = try await run(["capture-pane", "-p", "-J", "-t", "%0"]).stdoutString
            #expect(screen.contains(filename) == (phase == "fresh" || phase == "legacy"))
            #expect(try await run(["list-buffers", "-F", "#{buffer_name}"]).stdoutString.isEmpty)
        }
    }

    @Test("Input checks the actual tmux server, including recycled runtime and persistent pane IDs")
    func restart() async throws {
        try await withTmux { tmux, _, run in
            let paneID = UUID()
            let before = try await setup(run, paneID: paneID)
            try await tmux.sendKeystrokes("%0", keys: [.text("literal 'quote' ; "), .enter], expectedWorkspacePane: before)
            _ = try await run(["kill-server"])
            let after = try await setup(run, paneID: paneID)
            #expect(before.serverID != after.serverID)
            let executor = TmuxCommandExecutor(tmuxService: tmux)
            for command in [SendKeystroke([.text("STALE_KEY")]).commandType, SendRawInput(data: Data("STALE_RAW".utf8)).commandType, PasteTerminalText(text: "STALE_PASTE\n").commandType, CancelOperation().commandType] {
                let result = await executor.execute(.init(paneId: "%0", command: command, expectedWorkspacePane: before))
                #expect(!result.success)
            }
            let text = "fresh 'quote' ; 中文"
            try await tmux.sendKeystrokes("%0", keys: [.text(text), .enter], expectedWorkspacePane: after)
            try await tmux.loadAndPasteBuffer(target: "%0", content: "paste-ok\n", bufferName: "identity-paste", preserveLineFeeds: true, expectedWorkspacePane: after)
            try await Task.sleep(for: .milliseconds(100))
            let screen = try await run(["capture-pane", "-p", "-t", "%0"])
            #expect(screen.stdoutString.contains(text))
            #expect(screen.stdoutString.contains("paste-ok"))
            #expect(!screen.stdoutString.contains("STALE"))
            let buffers = try await run(["list-buffers", "-F", "#{buffer_name}"])
            #expect(buffers.stdoutString.isEmpty)
        }
    }

    @Test("Control-mode raw input checks identity without a process fallback")
    func controlInput() async throws {
        try await withTmux { _, manager, run in
            let original = try await setup(run, paneID: UUID())
            try await manager.registerPaneDimensions(paneId: "%0", sessionName: "input", dimensions: (120, 30))
            #expect(try await manager.sendRawBytesIfConnected(paneId: "%0", sessionName: "input", data: Data("before\n".utf8), expectedWorkspacePane: original))
            _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, UUID().uuidString])
            await #expect(throws: (any Error).self) {
                try await manager.sendRawBytesIfConnected(paneId: "%0", sessionName: "input", data: Data("STALE\n".utf8), expectedWorkspacePane: original)
            }
            let sentinel = try await manager.sendCommand("display-message -p after-guard", sessionName: "input")
            #expect(sentinel.output == "after-guard" && !sentinel.isError)
            _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, original.paneID.uuidString])
            #expect(try await manager.sendRawBytesIfConnected(paneId: "%0", sessionName: "input", data: Data("after\n".utf8), expectedWorkspacePane: original))
            try await Task.sleep(for: .milliseconds(100))
            let screen = try await run(["capture-pane", "-p", "-t", "%0"])
            #expect(screen.stdoutString.contains("before"))
            #expect(screen.stdoutString.contains("after"))
            #expect(!screen.stdoutString.contains("STALE"))
        }
    }

    @Test("A suspended native plugin write cannot enter a reconstructed terminal")
    func retiredPluginResponse() async throws {
        try await withTmux { tmux, _, run in
            let original = try await setup(run, paneID: UUID())
            let pane = PaneState(paneId: "%0", workspaceIdentity: original)
            let context = try PluginResponseContext(pluginID: "echo", pane: pane, requestID: nil)
            let (started, signalStarted) = AsyncStream<Void>.makeStream()
            let (resume, signalResume) = AsyncStream<Void>.makeStream()
            defer { signalStarted.finish()
                signalResume.finish()
            }
            let outcomes = LockIsolated<[Bool]>([])
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-response-input-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let host = LivePluginHost(pluginID: "echo", dispatcher: PluginEventDispatcher(), logSink: PluginLogSink(logFileURL: root.appendingPathComponent("test.log")), onSendText: { _, target, text in
                guard let bound = PluginResponseContext.current else { Issue.record("Lost response target")
                    return
                }
                signalStarted.yield()
                for await _ in resume {
                    break
                }
                do {
                    try await tmux.sendKeys(target, keys: text, literal: true, expectedWorkspacePane: bound.workspaceIdentity)
                    outcomes.withValue { $0.append(true) }
                } catch { outcomes.withValue { $0.append(false) } }
            })
            let core = EchoPluginCore()
            try await core.initialize(.init(pluginRoot: root, stateDir: root, appVersion: "3.0.75", settings: Data(), marketplaceSource: root), host: host)
            let pending = Task {
                await PluginResponseContext.$current.withValue(context) {
                    await core.deliverResponse(sessionID: "%0", requestID: "old", .prompt(text: "STALE_RESPONSE"))
                }
            }
            for await _ in started {
                break
            }
            _ = try await run(["kill-server"])
            let replacement = try await setup(run, paneID: original.paneID)
            signalResume.finish()
            await pending.value
            let fresh = try PluginResponseContext(pluginID: "echo", pane: .init(paneId: "%0", workspaceIdentity: replacement), requestID: nil)
            await PluginResponseContext.$current.withValue(fresh) {
                await core.deliverResponse(sessionID: "%0", requestID: "fresh", .prompt(text: "FRESH_RESPONSE"))
            }
            #expect(outcomes.value == [false, true])
            let screen = try await run(["capture-pane", "-p", "-t", "%0"])
            #expect(screen.stdoutString.contains("FRESH_RESPONSE"))
            #expect(!screen.stdoutString.contains("STALE_RESPONSE"))
            await core.shutdown()
        }
    }

    @Test("Files source reads reject a reconstructed server even before its metadata is published", arguments: [false, true])
    func retiredFileSource(repository: Bool) async throws {
        try await withTmux { tmux, controls, run in
            let original = try await setup(run, paneID: UUID())
            let (started, signalStarted) = AsyncStream<Void>.makeStream()
            let (resume, signalResume) = AsyncStream<Void>.makeStream()
            defer { signalStarted.finish()
                signalResume.finish()
            }
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[LoginItemService.self] = .previewValue
                $0[SessionDirectoryClient.self].resolve = { $0 }
                $0[FileBrowserClient.self].request = { operation in
                    signalStarted.yield()
                    for await _ in resume {
                        break
                    }
                    guard case let .list(path?, _, _) = operation else { throw FileBrowserError.message("Missing directory") }
                    return .listing(.init(directory: path, homeDirectory: "/Host", entries: [], nextOffset: nil, revision: "1"))
                }
                $0[FileBrowserClient.self].repositoryFile = { path, directory in
                    signalStarted.yield()
                    for await _ in resume {
                        break
                    }
                    return .init(path: directory + "/" + path, name: path, kind: .text, size: 0, revision: "1")
                }
            } operation: {
                let windows = MirrorWindowManager(
                    settings: AppSettings(),
                    tmuxService: tmux,
                    paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: controls),
                    editorSessionManager: EditorSessionManager()
                )
                var pane = PaneState(paneId: "%0", agentSession: .init(paneId: "%0", pluginID: "codex", detectedProjectPath: "/Host/project"), workspaceIdentity: original)
                windows.setPaneStatesForPreview([pane])
                let source = FileBrowserSource.local(paneID: "%0", tmux: tmux, windows: windows)
                let context = try #require(RepositoryFileContext(pane: pane))
                let operation: FileBrowserOperation = repository ? .repositoryInfo(path: "README.md", context: context) : .list(path: nil, offset: 0, includeHidden: false)
                let pending = Task { try await source.request(operation) }
                defer { pending.cancel() }
                for await _ in started {
                    break
                }
                _ = try await run(["kill-server"])
                let replacement = try await setup(run, paneID: original.paneID)
                #expect(original.serverID != replacement.serverID)
                // Keep the published cache stale; the final check must read tmux.
                signalResume.finish()
                await #expect(throws: (any Error).self) { try await pending.value }
                await #expect(throws: (any Error).self) { try await source.request(operation) }
                pane.workspaceIdentity = replacement
                windows.setPaneStatesForPreview([pane])
                await #expect(throws: (any Error).self) { try await source.request(operation) }
                // A current source may follow its directory; a live move doesn't
                // invalidate it, and explicit paths don't depend on the terminal.
                let fresh = FileBrowserSource.local(paneID: "%0", tmux: tmux, windows: windows)
                pane.workspaceIdentity?.sessionID = UUID()
                pane.workspaceIdentity?.windowID = UUID()
                windows.setPaneStatesForPreview([pane])
                _ = try await fresh.request(operation)
                _ = try await source.request(.list(path: "/Host/chosen", offset: 0, includeHidden: false))
                let remoteStale = FileBrowserSource.local(paneID: "%0", tmux: tmux, windows: windows, expectedWorkspacePane: original)
                await #expect(throws: (any Error).self) { try await remoteStale.request(operation) }
            }
        }
    }

    @Test("Streaming snapshots reject recycled tmux IDs in the same ordered capture")
    func streamCaptureIdentity() async throws {
        try await withTmux { tmux, manager, run in
            let persistentID = UUID()
            let original = try await setup(run, paneID: persistentID)
            _ = try await run(["kill-server"])
            let replacement = try await setup(run, paneID: persistentID)
            #expect(original.serverID != replacement.serverID)
            try await tmux.sendKeys("%0", keys: "RESTORED_CONTENT", literal: true, expectedWorkspacePane: replacement)
            await #expect(throws: (any Error).self) {
                try await tmux.capturePaneViaControlMode(paneId: "%0", width: 120, height: 30, controlClientManager: manager, sessionName: "input", expectedWorkspacePane: original)
            }
            let fresh = try await tmux.capturePaneViaControlMode(paneId: "%0", width: 120, height: 30, controlClientManager: manager, sessionName: "input", expectedWorkspacePane: replacement)
            #expect(String(decoding: fresh, as: UTF8.self).contains("RESTORED_CONTENT"))
            let sentinel = try await manager.sendCommand("display-message -p after-capture", sessionName: "input")
            #expect(sentinel.output == "after-capture" && !sentinel.isError)
        }
    }

    @MainActor
    final private class StreamSender: TerminalStreamSending {
        var frames: [TerminalStreamMessage] = []
        func sendTerminalStream(_ message: TerminalStreamMessage, to _: Set<String>, leaseIDs _: [String: UUID]) async {
            frames.append(message)
        }
    }

    @Test("A stale start cannot evict a healthy subscription for the reused pane route")
    func staleStartPreservesCurrentStream() async throws {
        try await withTmux { tmux, manager, run in
            let current = try await setup(run, paneID: UUID())
            let fifo = URL(fileURLWithPath: "/tmp/ctrlx-stream-identity-\(UUID())")
            try FileManager.default.createDirectory(at: fifo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fifo) }
            let panes = PaneStreamManager(tmuxService: tmux, controlClientManager: manager, fifoDirectory: fifo)
            let sender = StreamSender()
            let service = TerminalStreamService(streamSender: sender, paneStreamManager: panes)
            do {
                try await service.startStreaming(paneId: "%0", target: "%0", viewerId: "viewer", leaseId: UUID(), expectedWorkspacePane: current)
                #expect(service.isStreaming(paneId: "%0"))
                var stale = current
                stale.serverID = "1:1"
                await #expect(throws: (any Error).self) {
                    try await service.startStreaming(paneId: "%0", target: "%0", viewerId: "viewer", leaseId: UUID(), expectedWorkspacePane: stale)
                }
                #expect(service.isStreaming(paneId: "%0"))
                #expect(!sender.frames.contains { $0.updateType == .streamEnd })
            } catch {
                await service.stopAllStreams()
                await panes.disconnectAll()
                throw error
            }
            await service.stopAllStreams()
            await panes.disconnectAll()
        }
    }
}
