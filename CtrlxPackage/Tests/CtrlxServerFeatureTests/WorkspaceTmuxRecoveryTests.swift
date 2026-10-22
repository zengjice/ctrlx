import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct WorkspaceTmuxRecoveryTests {
    @Test("Restoration cannot mutate targets replaced after capture or between commands", arguments: [
        "after-snapshot", "before-resize", "before-split", "before-layout", "after-layout",
        "server-identity", "session-identity", "window-identity", "pane-identity",
    ])
    func restorationTargetChanges(interruption: String) async throws {
        try await withTmux { original, run, directory in
            try #require(try await run(["new-session", "-d", "-s", "project", "-x", "120", "-y", "40", "-c", directory.path, "/bin/cat"]).isSuccess)
            try #require(try await run(["split-window", "-h", "-t", "project:0", "-c", directory.path, "/bin/cat"]).isSuccess)
            let saved = try await original.capture()
            let session = try #require(saved.sessions.first)
            let window = try #require(session.windows.first)
            let sourcePane = try #require(window.panes.first { $0.runtimeID == "%0" })
            try #require(try await run([
                "kill-pane", "-t", "%1", ";",
                "resize-window", "-t", "@0", "-x", "80", "-y", "24", ";",
                "set-option", "-t", "$0", WorkspaceTmuxRecovery.sessionIncompleteKey, "1", ";",
                "set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowIncompleteKey, "1",
            ]).isSuccess)
            let replaced = LockIsolated(false)
            let baseline = LockIsolated("")
            let inspection = ["list-panes", "-a", "-F", "#{session_name}|#{window_id}|#{pane_id}|#{pane_pid}|#{window_width}x#{window_height}|#{@ctrlx-recovery-session}|#{@ctrlx-recovery-window}|#{@ctrlx-recovery-pane}|#{@ctrlx-recovery-window-incomplete}"]
            let replace: @Sendable () async throws -> Void = {
                guard
                    !replaced.withValue({ value in
                        let wasReplaced = value
                        value = true
                        return wasReplaced
                    }) else { return }
                if interruption == "session-identity" {
                    try #require(try await run(["set-option", "-t", "$0", WorkspaceTmuxRecovery.sessionKey, UUID().uuidString]).isSuccess)
                } else if interruption == "window-identity" {
                    try #require(try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, UUID().uuidString]).isSuccess)
                } else if interruption == "pane-identity" {
                    try #require(try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, UUID().uuidString]).isSuccess)
                } else {
                    try #require(try await run(["kill-server"]).isSuccess)
                    var args = ["new-session", "-d", "-s", "unrelated", "-x", "80", "-y", "24", "-c", directory.path, "/bin/cat"]
                    if interruption != "after-layout" {
                        let sameIDs = interruption == "server-identity"
                        args += [
                            ";", "set-option", "-t", "$0", WorkspaceTmuxRecovery.sessionKey, (sameIDs ? session.id : UUID()).uuidString,
                            ";", "set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, (sameIDs ? window.id : UUID()).uuidString,
                            ";", "set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, (sameIDs ? sourcePane.id : UUID()).uuidString,
                        ]
                    }
                    try #require(try await run(args).isSuccess)
                }
                let observed = try await run(inspection).stdoutString
                baseline.setValue(observed)
            }
            let command = switch interruption {
            case "before-split",
                 "pane-identity": "split-window"
            case "before-layout",
                 "after-layout": "select-layout"
            default: "resize-window"
            }
            let recovery = WorkspaceTmuxRecovery(run: { args in
                let matches = args.joined(separator: " ").contains(command)
                if interruption != "after-snapshot", interruption != "after-layout", matches {
                    try await replace()
                }
                let result = try await run(args)
                if interruption == "after-layout", matches {
                    try await replace()
                }
                return result
            }, shell: {
                if interruption == "after-snapshot" {
                    do { try await replace() }
                    catch { Issue.record("Fixture could not replace tmux: \(error)") }
                }
                return ("exec /bin/sh", [])
            }, system: .liveValue)
            await #expect(throws: (any Error).self) { try await recovery.restore(saved.sessions) }
            #expect(replaced.value)
            #expect(!baseline.value.isEmpty)
            #expect(try await run(inspection).stdoutString == baseline.value, "Rejected recovery must preserve dimensions, pane count, processes and identities")
        }
    }

    @MainActor
    @Test("Large workspaces receive stable identities without exceeding tmux's command limit", arguments: [false, true])
    func largeIdentityAssignment(discovery: Bool) async throws {
        try await withTmux { recovery, run, directory in
            for index in 0..<40 {
                try #require(try await run(["new-session", "-d", "-s", "project-\(index)", "-c", directory.path, "/bin/cat"]).isSuccess)
            }
            try #require(try await run(["new-session", "-d", "-s", "linked", "-t", "project-0"]).isSuccess)
            let preserved = UUID().uuidString
            try #require(try await run(["set-option", "-p", "-t", "project-0:0.0", WorkspaceTmuxRecovery.paneKey, preserved]).isSuccess)
            let processes = try await run(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]).stdoutString
            var partialIdentities: Set<String> = []
            if !discovery {
                let calls = LockIsolated(0)
                let interrupted = WorkspaceTmuxRecovery(run: { args in
                    if
                        args.first == "if-shell", calls.withValue({ $0 += 1
                            return $0 }) == 2 {
                        throw WorkspaceRecoveryError("Interrupted between identity batches")
                    }
                    return try await run(args)
                }, shell: { ("exec /bin/sh", []) }, system: .liveValue)
                await #expect(throws: WorkspaceRecoveryError.self) { try await interrupted.capture() }
                let assigned = try await run(["list-panes", "-a", "-F", "#{@ctrlx-recovery-session} #{@ctrlx-recovery-window} #{@ctrlx-recovery-pane}"]).stdoutString
                partialIdentities = Set(assigned.split(whereSeparator: \.isWhitespace).map(String.init))
                #expect(partialIdentities.count > 1)
            }
            if discovery {
                try await withDependencies {
                    $0[ProcessRunner.self] = .liveValue
                    $0.continuousClock = ContinuousClock()
                } operation: {
                    let service = try TmuxService(tmuxPath: #require(TmuxBinaryLocator.liveValue.find()), socketPath: directory.appendingPathComponent("tmux.sock").path)
                    let panes = await service.refreshPanes()
                    try #require(panes.count == 40)
                    #expect(panes.allSatisfy { $0.workspaceIdentity != nil })
                    #expect(service.lastError == nil)
                }
            }
            let captured = try await recovery.capture()
            #expect(captured.sessions.count == 41)
            #expect(Set(captured.sessions.map(\.id)).count == 41)
            #expect(Set(captured.sessions.flatMap(\.windows).map(\.id)).count == 40)
            #expect(Set(captured.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id)).count == 40)
            let identities = Set((captured.sessions.map(\.id) + captured.sessions.flatMap(\.windows).map(\.id) + captured.sessions.flatMap(\.windows).flatMap(\.panes).map(\.id)).map(\.uuidString))
            #expect(partialIdentities.isSubset(of: identities))
            #expect(try await recovery.capture() == captured)
            #expect(try await run(["show-options", "-pv", "-t", "project-0:0.0", WorkspaceTmuxRecovery.paneKey]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == preserved)
            #expect(try await run(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]).stdoutString == processes)
        }
    }

    @MainActor
    @Test("Discovery gives new terminals usable identities even when recovery is disabled or its journal cannot load", arguments: [false, true])
    func identityWithoutCheckpoints(corruptJournal: Bool) async throws {
        try await withTmux { tmux, run, directory in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/cat"]).isSuccess)
            let original = WorkspaceRecoveryStoreTests.snapshot()
            let saved = LockIsolated(original)
            let writes = LockIsolated(0)
            let store = WorkspaceRecoveryStore(load: {
                if corruptJournal {
                    throw WorkspaceRecoveryError("Invalid fixture journal")
                }
                return saved.value
            }, save: { value in
                writes.withValue { $0 += 1 }
                saved.setValue(value)
                return value
            })
            let recovery = WorkspaceRecoveryController(
                store: store, tmux: tmux.client, system: .liveValue, mode: { .disabled },
                captureExtras: { $0 }, present: { _, _ in Issue.record("Disabled recovery must not restore presentation") },
                resumeAgents: { source, _, _, _ in
                    Issue.record("Disabled recovery must not resume Agents")
                    return (source, [])
                }
            )
            await recovery.start(periodic: false)
            #expect(try await run(["new-window", "-d", "-t", "project", "/bin/cat"]).isSuccess)
            #expect(try await run(["split-window", "-h", "-t", "project:1", "/bin/cat"]).isSuccess)
            #expect(try await run(["new-session", "-d", "-s", "late", "/bin/cat"]).isSuccess)
            #expect(try await run(["new-session", "-d", "-s", "linked", "-t", "project"]).isSuccess)
            await recovery.checkpoint()
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = try TmuxService(tmuxPath: #require(TmuxBinaryLocator.liveValue.find()), socketPath: directory.appendingPathComponent("tmux.sock").path)
                let panes = await service.refreshPanes()
                #expect(panes.count == 4)
                try #require(panes.allSatisfy { $0.workspaceIdentity != nil })
                let states = Dictionary(uniqueKeysWithValues: panes.map { ($0.paneId, $0.makePaneState()) })
                var input = ViewerWorkspaceInputState()
                input.update(.init(pairId: "fixture", paneStates: states, workspaceIdentity: HostSessionStateSnapshot.workspaceIdentity(hostID: original.hostID, panes: states), supportsWorkspaceInputIdentity: true))
                for pane in panes {
                    let binding = input.binding(paneID: pane.paneId)
                    #expect(try binding.expectedPane(current: binding) == pane.workspaceIdentity)
                }
                let again = await service.refreshPanes()
                #expect(Set(again) == Set(panes))
                let sessionIDs = try await run(["list-sessions", "-F", "#{@ctrlx-recovery-session}"]).stdoutString.split(separator: "\n")
                #expect(sessionIDs.count == 3 && Set(sessionIDs).count == 3)
            }
            await recovery.stop()
            #expect(writes.value == 0 && saved.value == original)
        }
    }

    @Test("A stale capture cannot overwrite concurrent UUIDs or assign them to a replacement server", arguments: [false, true])
    func concurrentIdentityAssignment(restarted: Bool) async throws {
        try await withTmux { _, run, _ in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/cat"]).isSuccess)
            let identity = (session: UUID(), window: UUID(), pane: UUID())
            let assigned = LockIsolated(false)
            let recovery = WorkspaceTmuxRecovery(run: { args in
                let result = try await run(args)
                if
                    args.first == "list-panes", assigned.withValue({ flag in
                        guard !flag else { return false }
                        flag = true
                        return true
                    }) {
                    if restarted {
                        _ = try await run(["kill-server"])
                        _ = try await run(["new-session", "-d", "-s", "project", "/bin/cat"])
                    } else {
                        _ = try await run(["set-option", "-t", "project", WorkspaceTmuxRecovery.sessionKey, identity.session.uuidString])
                        _ = try await run(["set-option", "-w", "-t", "@0", WorkspaceTmuxRecovery.windowKey, identity.window.uuidString])
                        _ = try await run(["set-option", "-p", "-t", "%0", WorkspaceTmuxRecovery.paneKey, identity.pane.uuidString])
                    }
                }
                return result
            }, shell: { ("exec /bin/sh", []) }, system: .liveValue)
            if restarted {
                await #expect(throws: WorkspaceRecoveryError.self) { try await recovery.capture() }
                let options = try await run(["display-message", "-p", "-t", "%0", "#{@ctrlx-recovery-session}#{@ctrlx-recovery-window}#{@ctrlx-recovery-pane}"])
                #expect(options.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(try await recovery.capture().sessions.count == 1)
                return
            }
            let state = try await recovery.capture()
            #expect(state.sessions.first?.id == identity.session)
            #expect(state.sessions.first?.windows.first?.id == identity.window)
            #expect(state.sessions.first?.windows.first?.panes.first?.id == identity.pane)
        }
    }

    @Test("Transient empty cwd metadata is reread without inventing a directory", arguments: [2, 4, 20])
    func transientDirectoryCapture(missingReads: Int) async throws {
        try await withTmux { _, run, directory in
            #expect(try await run(["new-session", "-d", "-s", "project", "-c", directory.path, "/bin/sh"]).isSuccess)
            let reads = LockIsolated(0)
            let recovery = WorkspaceTmuxRecovery(run: { arguments in
                let result = try await run(arguments)
                guard arguments.first == "list-panes" else { return result }
                let count = reads.withValue { $0 += 1
                    return $0
                }
                guard count <= missingReads else { return result }
                let lines = result.stdoutString.split(separator: "\n").map { line in
                    var fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                    fields[14] = ""
                    return fields.joined(separator: "\u{1f}")
                }
                return ProcessResult(exitCode: result.exitCode, stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: result.stderr)
            }, shell: { ("exec /bin/sh", []) }, system: .liveValue)

            if missingReads == 20 {
                await #expect(throws: WorkspaceRecoveryError.self) { try await recovery.capture() }
                #expect(reads.value < missingReads)
            } else {
                let captured = try await recovery.capture()
                #expect(captured.sessions.count == 1)
                let expected = try await run(["display-message", "-p", "-t", "project:0", "#{pane_current_path}"])
                #expect(captured.sessions[0].windows[0].panes[0].directory == expected.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    @Test("An internal editor probe is excluded before assigning workspace identities", arguments: [false, true])
    func internalProbeCapture(disappearsDuringCapture: Bool) async throws {
        try await withTmux { _, run, _ in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/sh"]).isSuccess)
            let probe = EditorOverride.probeSessionPrefix
            #expect(try await run(["new-session", "-d", "-s", probe, "/bin/sh"]).isSuccess)
            let removed = LockIsolated(false)
            let recovery = WorkspaceTmuxRecovery(run: { arguments in
                let result = try await run(arguments)
                if
                    arguments.first == "list-panes", disappearsDuringCapture, removed.withValue({ done in
                        guard !done else { return false }
                        done = true
                        return true
                    }) {
                    #expect(try await run(["kill-session", "-t", "=\(probe)"]).isSuccess)
                }
                return result
            }, shell: { ("exec /bin/sh", []) }, system: .liveValue)

            let captured = try await recovery.capture()
            #expect(captured.sessions.map(\.name) == ["project"])
            if !disappearsDuringCapture {
                let identity = try await run(["display-message", "-p", "-t", "\(probe):0", "#{@ctrlx-recovery-pane}"])
                #expect(identity.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @MainActor
    @Test("Closure callbacks identify the actual object and only follow a successful tmux mutation", arguments: WorkspaceRecoveryCloseRequest.Kind.allCases, [false, true])
    func closureCallbacks(kind: WorkspaceRecoveryCloseRequest.Kind, fails: Bool) async {
        let identity = UUID()
        var observed: [WorkspaceRecoveryClosedTarget] = []
        await withDependencies {
            $0[ProcessRunner.self].run = { _, args, _, _ in
                if args.first == "display-message" {
                    #expect(args.last == kind.captureFormat)
                    return ProcessResult(exitCode: 0, stdout: Data("123:45\u{1f}\(kind.prefix)9\u{1f}\(identity.uuidString)\n".utf8), stderr: Data())
                }
                return ProcessResult(exitCode: fails && args.first == "if-shell" ? 1 : 0, stdout: args.first == "if-shell" ? Data("\(identity.uuidString)\n".utf8) : Data(), stderr: Data("fixture failure".utf8))
            }
        } operation: {
            let service = TmuxService(tmuxPath: "/fixture/tmux")
            service.workspaceCloseHandler = { operation in
                if let target = try await operation() {
                    observed.append(target)
                }
            }
            do {
                switch kind {
                case .session: try await service.killSession("project")
                case .window: try await service.killWindow("project:7")
                case .pane: try await service.killPane("%9")
                }
                #expect(!fails)
            } catch {
                #expect(fails)
            }
        }
        let expected: WorkspaceRecoveryClosedTarget = kind == .session ? .session(identity) : (kind == .window ? .window(identity) : .pane(identity))
        #expect(observed == (fails ? [] : [expected]))
    }

    @Test("Guarded close reports the persistent target, including UUIDs assigned while queued", arguments: WorkspaceRecoveryCloseRequest.Kind.allCases, [false, true])
    func guardedClose(kind: WorkspaceRecoveryCloseRequest.Kind, alreadyAssigned: Bool) async throws {
        try await withTmux { recovery, run, _ in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/sh"]).isSuccess)
            if alreadyAssigned {
                _ = try await recovery.capture()
            }
            let queried = try await run(["display-message", "-p", "-t", "project:0", kind.captureFormat])
            let request = try WorkspaceRecoveryCloseRequest(kind: kind, output: queried.stdoutString)
            let before = try await recovery.capture()
            let session = try #require(before.sessions.first)
            let window = try #require(session.windows.first)
            let pane = try #require(window.panes.first)
            let expected: WorkspaceRecoveryClosedTarget = kind == .session ? .session(session.id) : (kind == .window ? .window(window.id) : .pane(pane.id))
            #expect(try await request.closedTarget(run(request.arguments)) == expected)
            #expect(try await recovery.capture().sessions.isEmpty)
        }
    }

    @Test("A queued close cannot kill a replacement incarnation or identity", arguments: WorkspaceRecoveryCloseRequest.Kind.allCases, [false, true])
    func staleClose(kind: WorkspaceRecoveryCloseRequest.Kind, restart: Bool) async throws {
        try await withTmux { recovery, run, _ in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/sh"]).isSuccess)
            let original = try await recovery.capture()
            let queried = try await run(["display-message", "-p", "-t", "project:0", kind.captureFormat])
            let request = try WorkspaceRecoveryCloseRequest(kind: kind, output: queried.stdoutString)
            if restart {
                #expect(try await run(["kill-server"]).isSuccess)
                let restored = try await recovery.restore(original.sessions)
                #expect(restored.failures.isEmpty)
                #expect(restored.state.serverID != original.serverID)
            } else {
                let scope: [String] = kind == .session ? [] : (kind == .window ? ["-w"] : ["-p"])
                #expect(try await run(["set-option"] + scope + ["-t", request.runtimeID, kind.identityKey, UUID().uuidString]).isSuccess)
            }
            let pid = try await run(["display-message", "-p", "-t", "project:0", "#{pane_pid}"]).stdoutString
            let result = try await run(request.arguments)
            #expect(result.isSuccess && result.stdoutString.contains(WorkspaceRecoveryCloseRequest.rejection))
            #expect(throws: WorkspaceRecoveryError.self) { try request.closedTarget(result) }
            #expect(try await run(["display-message", "-p", "-t", "project:0", "#{pane_pid}"]).stdoutString == pid)
        }
    }

    @Test("A queued window close follows the original physical window after its index changes")
    func movedCloseTarget() async throws {
        try await withTmux { recovery, run, _ in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/sh"]).isSuccess)
            let original = try await recovery.capture()
            let window = try #require(original.sessions.first?.windows.first)
            let queried = try await run(["display-message", "-p", "-t", "project:0", WorkspaceRecoveryCloseRequest.Kind.window.captureFormat])
            let request = try WorkspaceRecoveryCloseRequest(kind: .window, output: queried.stdoutString)
            #expect(try await run(["move-window", "-s", "project:0", "-t", "project:7", ";", "new-window", "-d", "-t", "project:0", "/bin/sh"]).isSuccess)
            let pid = try await run(["display-message", "-p", "-t", "project:0", "#{pane_pid}"]).stdoutString
            #expect(try await request.closedTarget(run(request.arguments)) == .window(window.id))
            let after = try await recovery.capture()
            #expect(after.sessions.first?.windows.map(\.index) == [0])
            #expect(try await run(["display-message", "-p", "-t", "project:0", "#{pane_pid}"]).stdoutString == pid)
        }
    }

    @MainActor
    private func withTmux(_ test: @MainActor (WorkspaceTmuxRecovery, @escaping @Sendable ([String]) async throws -> ProcessResult, URL) async throws -> Void) async throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ctrlx-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("tmux.sock").path
        let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let path = try #require(executable, "tmux is required for recovery integration tests")
        let runner = ProcessRunner.liveValue
        let run: @Sendable ([String]) async throws -> ProcessResult = { args in
            try await withDependencies {
                $0.continuousClock = ContinuousClock()
            } operation: {
                try await runner.run(
                    executable: path,
                    arguments: ["-S", socket, "-f", "/dev/null"] + args,
                    environment: ["TMUX": "", "TMUX_PANE": ""],
                    timeout: 10
                )
            }
        }
        let recovery = WorkspaceTmuxRecovery(run: run, shell: { ("exec /bin/sh", []) }, system: .liveValue)
        do {
            try await test(recovery, run, directory)
        } catch {
            _ = try? await run(["kill-server"])
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = try? await run(["kill-server"])
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    @Test("The real tmux close API waits for an old journal capture before killing and saving")
    func closeTransactionIntegration() async throws {
        try await withTmux { tmux, run, directory in
            #expect(try await run(["new-session", "-d", "-s", "project", "/bin/sh"]).isSuccess)
            let paused = LockIsolated(false)
            let entered = AsyncStream<Void>.makeStream()
            let released = AsyncStream<Void>.makeStream()
            let requested = AsyncStream<Void>.makeStream()
            let client = WorkspaceTmuxClient(capture: {
                let state = try await tmux.capture()
                let shouldPause = paused.withValue { value in
                    let previous = value
                    value = false
                    return previous
                }
                if shouldPause {
                    entered.continuation.yield(())
                    for await _ in released.stream {
                        break
                    }
                }
                return state
            }, restore: { try await tmux.restore($0) })
            let store = WorkspaceRecoveryStore.inMemory()
            let recovery = WorkspaceRecoveryController(
                store: store, tmux: client,
                system: .init(bootID: { "fixture-boot" }, directoryExists: { _ in true }, pathExists: { _ in true }),
                mode: { .layoutAndAgents }, captureExtras: { $0 }, present: { _, _ in },
                resumeAgents: { source, _, _, _ in (source, []) }
            )
            await recovery.start(periodic: false)
            try #require(recovery.phase == .ready)
            let executable = try #require(TmuxBinaryLocator.liveValue.find())
            try await withDependencies {
                $0[ProcessRunner.self] = .liveValue
                $0.continuousClock = ContinuousClock()
            } operation: {
                let service = TmuxService(tmuxPath: executable, socketPath: directory.appendingPathComponent("tmux.sock").path)
                service.workspaceCloseHandler = { operation in
                    requested.continuation.yield(())
                    try await recovery.performClose(operation)
                }
                paused.setValue(true)
                let checkpoint = Task { await recovery.checkpoint() }
                for await _ in entered.stream {
                    break
                }
                let close = Task { try await service.killSession("project") }
                for await _ in requested.stream {
                    break
                }
                #expect(try await run(["has-session", "-t", "project"]).isSuccess)
                released.continuation.yield(())
                await checkpoint.value
                try await close.value
                #expect(try await tmux.capture().sessions.isEmpty)
                #expect(try await store.load()?.sessions.isEmpty == true)
                #expect(recovery.phase == .ready)
            }
            await recovery.stop()
        }
    }

    @Test("Real tmux restart restores distinct same-directory sessions, sparse tabs and nested panes")
    func restart() async throws {
        try await withTmux { recovery, run, directory in
            let first = try await run(["new-session", "-d", "-s", "alpha", "-x", "120", "-y", "40", "-c", directory.path, "/bin/sh"])
            #expect(first.isSuccess)
            _ = try await run(["split-window", "-h", "-t", "alpha:0", "-c", "/tmp", "/bin/sh"])
            _ = try await run(["split-window", "-v", "-t", "alpha:0.1", "-c", directory.path, "/bin/sh"])
            _ = try await run(["move-window", "-s", "alpha:0", "-t", "alpha:2"])
            _ = try await run(["new-window", "-d", "-t", "alpha:7", "-n", "other", "-c", "/tmp", "/bin/sh"])
            _ = try await run(["new-session", "-d", "-s", "beta", "-x", "90", "-y", "30", "-c", directory.path, "/bin/sh"])
            _ = try await run(["set-option", "-t", "alpha:", "@ctrlx-description", "same project / different work"])
            let before = try await recovery.capture()
            let again = try await recovery.capture()
            #expect(before == again)
            #expect(before.sessions.count == 2)
            #expect(before.sessions[0].windows.map(\.index) == [2, 7])
            let pidBefore = try await run(["list-panes", "-a", "-F", "#{pane_pid}"])
            let surviving = try await recovery.restore(before.sessions)
            #expect(surviving.failures.isEmpty)
            #expect(surviving.createdPaneIDs.isEmpty)
            #expect(try await run(["list-panes", "-a", "-F", "#{pane_pid}"]).stdoutString == pidBefore.stdoutString)
            _ = try await run(["kill-server"])
            #expect(try await recovery.capture().sessions.isEmpty)
            let restored = try await recovery.restore(before.sessions)
            #expect(restored.failures.isEmpty)
            #expect(restored.state.incompleteSessionIDs.isEmpty)
            #expect(restored.state.incompleteWindowIDs.isEmpty)
            #expect(restored.state.sessions.map(\.id) == before.sessions.map(\.id))
            for old in before.sessions {
                let current = try #require(restored.state.sessions.first { $0.id == old.id })
                #expect(current.name == old.name && current.description == old.description)
                #expect(current.windows.map(\.index) == old.windows.map(\.index))
                #expect(current.selectedWindowID == old.selectedWindowID)
                for window in old.windows {
                    let new = try #require(current.windows.first { $0.id == window.id })
                    #expect(new.layout == window.layout)
                    #expect(new.selectedPaneID == window.selectedPaneID)
                    #expect(new.panes.map(\.id) == window.panes.map(\.id))
                    #expect(new.panes.map(\.directory) == window.panes.map(\.directory))
                }
            }
            let resumedPIDs = try await run(["list-panes", "-a", "-F", "#{pane_pid}"])
            #expect(try await recovery.restore(before.sessions).createdPaneIDs.isEmpty)
            #expect(try await run(["list-panes", "-a", "-F", "#{pane_pid}"]).stdoutString == resumedPIDs.stdoutString)
        }
    }

    @Test("A missing directory retains its original split as a stopped placeholder")
    func partialFailure() async throws {
        try await withTmux { recovery, run, directory in
            var saved = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
            let missing = directory.appendingPathComponent("not-mounted")
            let extra = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%88", directory: missing.path)
            saved.windows[0].panes.append(extra)
            saved.windows[0].layout = .horizontal([
                .pane(saved.windows[0].panes[0].id, width: 59, height: 40),
                .pane(extra.id, width: 60, height: 40),
            ], width: 120, height: 40)
            let failed = try await recovery.restore([saved])
            #expect(failed.failures.isEmpty)
            #expect(failed.state.incompleteSessionIDs.isEmpty)
            #expect(failed.state.sessions[0].windows[0].panes.count == 2)
            #expect(failed.state.placeholderPaneIDs == [extra.id])
            #expect(failed.state.sessions[0].windows[0].panes.last?.directory == missing.path)
            #expect(failed.state.sessions[0].windows[0].layout == saved.windows[0].layout)
            let pid = try await run(["display-message", "-p", "-t", "project:", "#{pane_pid}"])
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            let retried = try await recovery.restore([saved])
            #expect(retried.failures.isEmpty)
            #expect(retried.state.sessions[0].windows[0].layout == saved.windows[0].layout)
            #expect(try await run(["display-message", "-p", "-t", "project:0.0", "#{pane_pid}"]).stdoutString == pid.stdoutString)
        }
    }

    @Test("Missing first directories preserve the whole workspace across restart and retry", arguments: [false, true])
    func missingDirectoryRestart(interruptedBeforeCheckpoint: Bool) async throws {
        try await withTmux { tmux, run, directory in
            let missing = directory.appendingPathComponent("not-mounted")
            var source = WorkspaceRecoveryStoreTests.snapshot()
            source.sessions[0].windows[0].panes[0].directory = missing.path
            let first = source.sessions[0].windows[0].panes[0]
            let available = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%88", directory: directory.path)
            source.sessions[0].windows[0].panes.append(available)
            source.sessions[0].windows[0].layout = .horizontal([
                .pane(first.id, width: 59, height: 40), .pane(available.id, width: 60, height: 40),
            ], width: 120, height: 40)
            let second = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%89", directory: missing.path)
            source.sessions[0].windows.append(.init(
                id: UUID(), runtimeID: "@88", index: 3, name: "second", selectedPaneID: second.id,
                layout: .pane(second.id, width: 120, height: 40), panes: [second]
            ))
            let store = WorkspaceRecoveryStore.diskBacked(directory: directory.appendingPathComponent("state"))
            if interruptedBeforeCheckpoint {
                source.recovery = .init(bootID: "new-boot", pendingAgentPaneIDs: [])
                _ = try await store.save(source)
                _ = try await tmux.restore(source.sessions)
            } else {
                _ = try await store.save(source)
            }
            var launches: [UUID] = []
            let agents = WorkspaceAgentRecovery(
                core: { _ in nil }, mode: { .layoutOnly }, refresh: { }, version: { _ in nil },
                directoryExists: WorkspaceRecoverySystem.liveValue.directoryExists,
                inspect: { runtime in
                    try WorkspaceAgentTerminal.parse(await run(["display-message", "-p", "-t", runtime, WorkspaceAgentTerminal.inspectionFormat]))
                },
                launch: { runtime, pane, record, command in
                    #expect(command == nil)
                    #expect(try await store.load()?.recovery?.agentLaunches[pane.id] == record)
                    try WorkspaceAgentTerminal.verifyLaunch(await run(WorkspaceAgentTerminal.launchArguments(
                        runtimeID: runtime, pane: pane, record: record, process: ["/bin/sh"], environment: []
                    )), record: record)
                    launches.append(pane.id)
                }
            )
            var presentations: [WorkspaceTmuxState] = []
            @MainActor
            func controller() -> WorkspaceRecoveryController {
                WorkspaceRecoveryController(
                    store: store, tmux: tmux.client,
                    system: .init(bootID: { "new-boot" }, directoryExists: WorkspaceRecoverySystem.liveValue.directoryExists, pathExists: WorkspaceRecoverySystem.liveValue.pathExists),
                    mode: { .layoutOnly }, captureExtras: { $0 },
                    present: { _, live in presentations.append(live) },
                    resumeAgents: { source, result, intent, save in
                        try await agents.recover(source, result: result, intent: intent, save: save)
                    }
                )
            }
            let recovery = controller()
            await recovery.start(periodic: false)
            // The inert process exits asynchronously; regular reconciliation must
            // retain the original directory and expose Retry once it is stopped.
            for _ in 0..<50 where recovery.failures.filter(\.blocksInput).count < 2 {
                try await Task.sleep(for: .milliseconds(20))
                await recovery.checkpoint()
            }
            #expect(recovery.phase == .needsRecovery)
            #expect(recovery.failures.count == 2)
            #expect(recovery.failures.allSatisfy { $0.blocksInput && $0.canRetry && $0.reason.contains(missing.path) })
            #expect(launches.isEmpty)
            let presented = try #require(presentations.last?.sessions.first)
            #expect(presented.windows.map(\.index) == [0, 3])
            #expect(presented.windows.map(\.layout) == source.sessions[0].windows.map(\.layout))
            let livePanes = presented.windows.flatMap(\.panes)
            let ordinary = try #require(livePanes.first { $0.id == available.id })
            let pid = try await run(["display-message", "-p", "-t", ordinary.runtimeID, "#{pane_pid}"]).stdoutString
            await recovery.checkpoint()
            await recovery.stop()
            let pending = try #require(try await store.load())
            #expect(pending.recovery?.pendingAgentPaneIDs == [first.id, second.id])
            #expect(pending.sessions[0].windows.flatMap(\.panes).filter { $0.id != available.id }.allSatisfy { $0.directory == missing.path })

            let restarted = controller()
            await restarted.start(periodic: false)
            #expect(restarted.phase == .needsRecovery)
            #expect(launches.isEmpty)
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            await restarted.retry()
            #expect(restarted.phase == .ready)
            #expect(Set(launches) == [first.id, second.id] && launches.count == 2)
            let restored = try await tmux.capture()
            #expect(restored.placeholderPaneIDs.isEmpty)
            #expect(restored.sessions[0].windows.flatMap(\.panes).map(\.runtimeID) == livePanes.map(\.runtimeID))
            let directories = restored.sessions[0].windows.flatMap(\.panes).filter { $0.id != available.id }.map(\.directory)
            #expect(directories.allSatisfy { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == missing.resolvingSymlinksInPath().path }, "Observed shell directories: \(directories); expected: \(missing.resolvingSymlinksInPath().path)")
            #expect(try await run(["display-message", "-p", "-t", ordinary.runtimeID, "#{pane_pid}"]).stdoutString == pid)
            await restarted.retry()
            #expect(launches.count == 2)
            #expect(try await store.load()?.recovery == nil)
            await restarted.stop()
        }
    }

    @Test("Shared windows recover as links with independent session indices and selections")
    func linkedWindows() async throws {
        try await withTmux { recovery, run, directory in
            #expect(try await run(["new-session", "-d", "-s", "alpha", "-x", "120", "-y", "40", "-c", directory.path, "/bin/sh"]).isSuccess)
            #expect(try await run(["split-window", "-h", "-t", "alpha:0", "-c", "/tmp", "/bin/sh"]).isSuccess)
            #expect(try await run(["move-window", "-s", "alpha:0", "-t", "alpha:2"]).isSuccess)
            #expect(try await run(["new-window", "-d", "-t", "alpha:9", "-c", "/tmp", "/bin/sh"]).isSuccess)
            #expect(try await run(["new-session", "-d", "-s", "beta", "-c", directory.path, "/bin/sh"]).isSuccess)
            #expect(try await run(["link-window", "-d", "-s", "alpha:2", "-t", "beta:7"]).isSuccess)
            #expect(try await run(["new-session", "-d", "-s", "gamma", "/bin/sh", ";", "link-window", "-k", "-s", "alpha:2", "-t", "gamma:0", ";", "move-window", "-s", "gamma:0", "-t", "gamma:4"]).isSuccess)
            #expect(try await run(["select-window", "-t", "alpha:9", ";", "select-window", "-t", "beta:7"]).isSuccess)
            let before = try await recovery.capture()
            let sharedID = try #require(before.sessions.first { $0.name == "alpha" }?.windows.first { $0.index == 2 }?.id)
            #expect(before.sessions.flatMap(\.windows).filter { $0.id == sharedID }.count == 3)
            #expect(try await run(["kill-server"]).isSuccess)

            let restored = try await recovery.restore(before.sessions)
            #expect(restored.failures.isEmpty)
            #expect(restored.state.incompleteSessionIDs.isEmpty && restored.state.incompleteWindowIDs.isEmpty)
            let links = restored.state.sessions.flatMap(\.windows).filter { $0.id == sharedID }
            #expect(links.count == 3 && Set(links.map(\.runtimeID)).count == 1)
            #expect(Set(links.map(\.index)) == [2, 7, 4])
            #expect(restored.createdPaneIDs.count == 4)
            for saved in before.sessions {
                let current = try #require(restored.state.sessions.first { $0.id == saved.id })
                #expect(current.windows.map(\.id) == saved.windows.map(\.id))
                #expect(current.windows.map(\.index) == saved.windows.map(\.index))
                #expect(current.windows.map(\.layout) == saved.windows.map(\.layout))
                #expect(current.selectedWindowID == saved.selectedWindowID)
            }
            let pids = try await run(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]).stdoutString
            #expect(Set(pids.split(separator: "\n")).count == 4)
            #expect(try await recovery.restore(before.sessions).createdPaneIDs.isEmpty)
            #expect(try await run(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]).stdoutString == pids)
        }
    }

    @Test("Recreating a missing session links its surviving window without resizing or replacing processes")
    func survivingLink() async throws {
        try await withTmux { recovery, run, directory in
            #expect(try await run(["new-session", "-d", "-s", "alpha", "-x", "120", "-y", "40", "-c", directory.path, "/bin/sh"]).isSuccess)
            #expect(try await run(["new-session", "-d", "-s", "beta", "/bin/sh", ";", "link-window", "-k", "-s", "alpha:0", "-t", "beta:0", ";", "move-window", "-s", "beta:0", "-t", "beta:7"]).isSuccess)
            let before = try await recovery.capture()
            #expect(try await run(["kill-session", "-t", "beta", ";", "resize-window", "-t", "alpha:0", "-x", "99", "-y", "29", ";", "set-option", "-g", "base-index", "3"]).isSuccess)
            let surviving = try await recovery.capture()
            let pid = try await run(["display-message", "-p", "-t", "alpha:0", "#{pane_pid}"]).stdoutString
            let restored = try await recovery.restore(before.sessions)
            #expect(restored.failures.isEmpty && restored.createdPaneIDs.isEmpty)
            let alpha = try #require(restored.state.sessions.first { $0.name == "alpha" })
            let beta = try #require(restored.state.sessions.first { $0.name == "beta" })
            #expect(alpha == surviving.sessions[0])
            #expect(beta.windows.count == 1 && beta.windows[0].index == 7)
            #expect(beta.windows[0].runtimeID == alpha.windows[0].runtimeID)
            #expect(beta.windows[0].layout == alpha.windows[0].layout)
            #expect(try await run(["display-message", "-p", "-t", "beta:7", "#{pane_pid}"]).stdoutString == pid)
            #expect(try Set(await run(["list-panes", "-a", "-F", "#{pane_id}"]).stdoutString.split(separator: "\n")).count == 1)
        }
    }

    @Test("An interrupted shared window is completed once and all session links remain retryable")
    func partialLinkedWindow() async throws {
        try await withTmux { _, run, directory in
            let blocked = LockIsolated(true)
            let recovery = WorkspaceTmuxRecovery(run: { args in
                if args.joined(separator: " ").contains("split-window"), blocked.value {
                    throw WorkspaceRecoveryError("Fixture interrupted pane creation")
                }
                return try await run(args)
            }, shell: { ("exec /bin/sh", []) }, system: .liveValue)
            var alpha = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
            let missing = directory.appendingPathComponent("not-mounted")
            let extra = WorkspaceRecoveryPane(id: UUID(), runtimeID: "%88", directory: missing.path)
            alpha.windows[0].panes.append(extra)
            alpha.windows[0].layout = .horizontal([
                .pane(alpha.windows[0].panes[0].id, width: 59, height: 40),
                .pane(extra.id, width: 60, height: 40),
            ], width: 120, height: 40)
            var beta = alpha
            beta.id = UUID()
            beta.runtimeID = "$2"
            beta.name = "linked"
            beta.windows[0].index = 7
            let failed = try await recovery.restore([alpha, beta])
            #expect(failed.failures.count == 1)
            #expect(failed.state.incompleteSessionIDs == [alpha.id, beta.id])
            #expect(failed.state.incompleteWindowIDs == [alpha.windows[0].id])
            #expect(failed.createdPaneIDs.count == 1)
            let pid = try await run(["display-message", "-p", "-t", "project:0", "#{pane_pid}"]).stdoutString
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            blocked.setValue(false)
            let retried = try await recovery.restore([alpha, beta])
            #expect(retried.failures.isEmpty)
            #expect(retried.state.incompleteSessionIDs.isEmpty && retried.state.incompleteWindowIDs.isEmpty)
            #expect(retried.createdPaneIDs == [extra.id])
            #expect(Set(retried.state.sessions.flatMap(\.windows).map(\.runtimeID)).count == 1)
            #expect(retried.state.sessions.flatMap(\.windows).allSatisfy { $0.layout == alpha.windows[0].layout })
            #expect(try await run(["display-message", "-p", "-t", "linked:7.0", "#{pane_pid}"]).stdoutString == pid)
        }
    }

    @Test("An unrelated session with the same name is preserved and reported")
    func nameConflict() async throws {
        try await withTmux { recovery, run, _ in
            _ = try await run(["new-session", "-d", "-s", "project", "-n", "terminal", "/bin/sh"])
            let existing = try await recovery.capture()
            let result = try await recovery.restore(WorkspaceRecoveryStoreTests.snapshot().sessions)
            #expect(result.failures.count == 1)
            #expect(result.createdPaneIDs.isEmpty)
            #expect(result.state == existing)
        }
    }

    @Test("Native launch owns only dead recovery placeholders and survives quoted paths and arguments", arguments: [false, true])
    func nativePlaceholder(asShell: Bool) async throws {
        try await withTmux { recovery, run, directory in
            let cwd = directory.appendingPathComponent("space 'quote' $literal")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            var saved = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
            saved.windows[0].panes[0].directory = cwd.path
            saved.windows[0].panes[0].unavailableAgentReason = "Fixture pending agent"
            let restored = try await recovery.restore([saved])
            #expect(restored.failures.isEmpty)
            let pane = try #require(restored.state.sessions.first?.windows.first?.panes.first)
            let record = try WorkspaceRecoveryAgentLaunch(serverID: #require(restored.state.serverID), runtimePaneID: pane.runtimeID, kind: asShell ? .shell : .resume)
            // Process exit is asynchronous relative to the create command queue.
            var state = try WorkspaceAgentTerminal.parse(await run(["display-message", "-p", "-t", pane.runtimeID, WorkspaceAgentTerminal.inspectionFormat]))
            for _ in 0..<50 where !state.isDead {
                try await Task.sleep(for: .milliseconds(20))
                state = try WorkspaceAgentTerminal.parse(await run(["display-message", "-p", "-t", pane.runtimeID, WorkspaceAgentTerminal.inspectionFormat]))
            }
            try #require(state.isDead && state.isPlaceholder && state.identity == pane.id)
            let marker = cwd.appendingPathComponent("argv.txt")
            let process = ["/bin/sh", "-c", "printf '%s' \"$1\" > \"$2\"; exec /bin/sleep 60", "fixture", "'quoted' ; $(never-run)", marker.path]
            let args = WorkspaceAgentTerminal.launchArguments(runtimeID: pane.runtimeID, pane: pane, record: record, process: process, environment: ["FIXTURE=value with space"])
            try WorkspaceAgentTerminal.verifyLaunch(await run(args), record: record)
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try String(contentsOf: marker, encoding: .utf8) == "'quoted' ; $(never-run)")
            state = try WorkspaceAgentTerminal.parse(await run(["display-message", "-p", "-t", pane.runtimeID, WorkspaceAgentTerminal.inspectionFormat]))
            #expect(!state.isDead && state.launchID == record.id)
            if asShell {
                #expect(try await run(["show-options", "-p", "-A", "-v", "-t", pane.runtimeID, "remain-on-exit"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "off")
            }
            let pid = try await run(["display-message", "-p", "-t", pane.runtimeID, "#{pane_pid}"]).stdoutString
            await #expect(throws: WorkspaceRecoveryError.self) { try WorkspaceAgentTerminal.verifyLaunch(await run(args), record: record) }
            #expect(try await run(["display-message", "-p", "-t", pane.runtimeID, "#{pane_pid}"]).stdoutString == pid)
            let retried = try await recovery.restore([saved])
            #expect(retried.createdPaneIDs.isEmpty && retried.failures.isEmpty)
        }
    }
}
