import ClaudeCodePluginCore
import CodexPluginCore
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import CtrlxPluginProtocol
import Testing
@testable import CtrlxServerFeature

private struct ForkGitFixture {
    let container: URL
    let root: URL
    var source: String { root.appendingPathComponent("src folder").path }

    static func make() async throws -> Self {
        let files = FileManager.default
        let container = files.temporaryDirectory.appendingPathComponent("cx-fork-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let root = container.appendingPathComponent("repo with space")
        try files.createDirectory(at: root.appendingPathComponent("src folder"), withIntermediateDirectories: true)
        let fixture = Self(container: container, root: root)
        _ = try await fixture.git(["init", "--initial-branch=main"])
        _ = try await fixture.git(["config", "user.name", "CtrlX Fork Test"])
        _ = try await fixture.git(["config", "user.email", "ctrlx-test@example.invalid"])
        _ = try await fixture.git(["config", "core.hooksPath", "/dev/null"])
        _ = try await fixture.git(["config", "core.excludesFile", "/dev/null"])
        _ = try await fixture.git(["config", "commit.gpgSign", "false"])
        try "committed".write(to: root.appendingPathComponent("src folder/file.txt"), atomically: true, encoding: .utf8)
        _ = try await fixture.git(["add", "."])
        _ = try await fixture.git(["commit", "-m", "fixture"])
        return fixture
    }

    func git(_ arguments: [String], at directory: String? = nil) async throws -> String {
        let result = try await ProcessRunner.liveValue.runOrThrow(executable: "/usr/bin/git", arguments: ["-C", directory ?? root.path] + arguments)
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func cleanUp() throws { try FileManager.default.removeItem(at: container) }
}

@MainActor
struct AgentForkWorktreeTests {
    private func live<T>(_ operation: () async throws -> T) async throws -> T {
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0[SessionDirectoryClient.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: { try await operation() }
    }

    @Test("A clean Git worktree starts at source HEAD, preserves subdirectory, and stays locally ignored")
    func cleanWorktree() async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(fixture.source)
            #expect(plan.primaryRoot == fixture.root.path)
            #expect(plan.relativeDirectory == "src folder")
            #expect(!plan.hasUncommittedChanges)
            let cwd = try await manager.create(fixture.source, request: .init(name: "new-agent", expectedHead: plan.head))
            let path = plan.directory(name: "new-agent")
            #expect(cwd == path + "/src folder")
            #expect(try await fixture.git(["rev-parse", "HEAD"], at: cwd) == plan.head)
            #expect(try await fixture.git(["branch", "--show-current"], at: cwd) == "new-agent")
            #expect(try String(contentsOfFile: cwd + "/file.txt", encoding: .utf8) == "committed")
            #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
            // Retrying with a different request must not overwrite an existing checkout.
            await #expect(throws: AgentForkError.self) { try await manager.create(fixture.source, request: .init(name: "new-agent", expectedHead: plan.head)) }
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test("Negated ignore rules must reject checkout rather than stage a nested repository", arguments: ["!*/\n", "/.worktrees/\n!/.worktrees/\n"])
    func overriddenExclude(ignoreRules: String) async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let ignoreFile = fixture.root.appendingPathComponent(".gitignore")
            try ignoreRules.write(to: ignoreFile, atomically: true, encoding: .utf8)
            _ = try await fixture.git(["add", ".gitignore"])
            _ = try await fixture.git(["commit", "-m", "ignore rules"])
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(fixture.source)
            #expect(!plan.hasUncommittedChanges)
            for _ in 0..<2 {
                do {
                    _ = try await manager.create(fixture.source, request: .init(name: "blocked", expectedHead: plan.head))
                    Issue.record("A worktree that is not ignored must not be created")
                } catch {
                    #expect(error.localizedDescription.contains("Git ignore rules override info/exclude"))
                    #expect(error.localizedDescription.contains(".gitignore"))
                }
            }
            #expect(!FileManager.default.fileExists(atPath: plan.directory(name: "blocked")))
            #expect(try await fixture.git(["branch", "--list", "blocked"]).isEmpty)
            #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
            #expect(try String(contentsOf: ignoreFile, encoding: .utf8) == ignoreRules)
            let excludePath = try await fixture.git(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"])
            let contents = try String(contentsOfFile: excludePath, encoding: .utf8)
            #expect(contents.components(separatedBy: "\n").filter { $0 == "/.worktrees/" }.count == 1)
            _ = try await fixture.git(["add", "."])
            #expect(try await fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        }
    }

    @Test("A tracked ignore rule can resolve an exclude conflict without being edited by Fork")
    func resolvedExcludeConflict() async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let ignoreRules = "!*/\n/.worktrees/\n"
            let ignoreFile = fixture.root.appendingPathComponent(".gitignore")
            try ignoreRules.write(to: ignoreFile, atomically: true, encoding: .utf8)
            _ = try await fixture.git(["add", ".gitignore"])
            _ = try await fixture.git(["commit", "-m", "ignore rules"])
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(fixture.source)
            _ = try await manager.create(fixture.source, request: .init(name: "allowed", expectedHead: plan.head))
            #expect(try String(contentsOf: ignoreFile, encoding: .utf8) == ignoreRules)
            #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
            _ = try await fixture.git(["add", "."])
            #expect(try await fixture.git(["diff", "--cached", "--name-only"]).isEmpty)
        }
    }

    @Test("Dirty source requires acknowledgment and never copies modified/untracked files")
    func dirtyWorktree() async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            try "dirty".write(toFile: fixture.source + "/file.txt", atomically: true, encoding: .utf8)
            try "untracked".write(to: fixture.root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(fixture.source)
            #expect(plan.hasUncommittedChanges)
            await #expect(throws: AgentForkError.self) { try await manager.create(fixture.source, request: .init(name: "clean", expectedHead: plan.head)) }
            #expect(!FileManager.default.fileExists(atPath: plan.directory(name: "clean")))
            let cwd = try await manager.create(fixture.source, request: .init(name: "clean", expectedHead: plan.head, allowUncommittedChanges: true))
            #expect(try String(contentsOfFile: cwd + "/file.txt", encoding: .utf8) == "committed")
            #expect(try String(contentsOfFile: fixture.source + "/file.txt", encoding: .utf8) == "dirty")
            #expect(!FileManager.default.fileExists(atPath: plan.directory(name: "clean") + "/untracked.txt"))
        }
    }

    @Test("Forking a linked worktree uses its HEAD, but places the new checkout under the primary repository")
    func linkedWorktree() async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let linked = fixture.container.appendingPathComponent("linked")
            _ = try await fixture.git(["worktree", "add", "-b", "linked", linked.path, "HEAD"])
            try "linked".write(to: linked.appendingPathComponent("src folder/file.txt"), atomically: true, encoding: .utf8)
            _ = try await fixture.git(["commit", "-am", "linked change"], at: linked.path)
            let manager = AgentForkWorktreeManager()
            let source = linked.appendingPathComponent("src folder").path
            let plan = try await manager.inspect(source)
            #expect(plan.primaryRoot == fixture.root.path)
            #expect(plan.head != (try await fixture.git(["rev-parse", "HEAD"])))
            let cwd = try await manager.create(source, request: .init(name: "child", expectedHead: plan.head))
            #expect(cwd == fixture.root.path + "/.worktrees/child/src folder")
            #expect(try String(contentsOfFile: cwd + "/file.txt", encoding: .utf8) == "linked")
        }
    }

    @Test("Stale HEAD, an existing branch and path traversal are rejected before checkout")
    func invalidDestination() async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(fixture.source)
            await #expect(throws: AgentForkError.self) { try await manager.create(fixture.source, request: .init(name: "../escape", expectedHead: plan.head)) }
            _ = try await fixture.git(["branch", "existing"])
            await #expect(throws: AgentForkError.self) { try await manager.create(fixture.source, request: .init(name: "existing", expectedHead: plan.head)) }
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "new HEAD"])
            await #expect(throws: AgentForkError.self) { try await manager.create(fixture.source, request: .init(name: "stale", expectedHead: plan.head)) }
            #expect(!FileManager.default.fileExists(atPath: plan.directory(name: "stale")))
        }
    }

    @Test("Existing exact branch or directory names prompt renaming without overwriting anything", arguments: ["branch", "directory"])
    func nameConflicts(kind: String) async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(fixture.source)
            let existingPath = plan.directory(name: "existing")
            if kind == "branch" {
                _ = try await fixture.git(["branch", "existing"])
            } else {
                try FileManager.default.createDirectory(atPath: existingPath, withIntermediateDirectories: true)
                try "keep me".write(toFile: existingPath + "/sentinel.txt", atomically: true, encoding: .utf8)
            }
            do {
                _ = try await manager.create(fixture.source, request: .init(name: "existing", expectedHead: plan.head, allowUncommittedChanges: true))
                Issue.record("An existing destination must not be reused")
            } catch {
                #expect(error.localizedDescription.contains(kind == "branch" ? "Branch already exists: existing" : "Worktree directory already exists:"))
                #expect(error.localizedDescription.contains("Choose a different name"))
            }
            #expect(try await fixture.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
            if kind == "branch" {
                #expect(try await fixture.git(["rev-parse", "existing"]) == plan.head)
                #expect(!FileManager.default.fileExists(atPath: existingPath))
            } else {
                #expect(try String(contentsOfFile: existingPath + "/sentinel.txt", encoding: .utf8) == "keep me")
                #expect(try await fixture.git(["branch", "--list", "existing"]).isEmpty)
            }
            let newPath = try await manager.create(fixture.source, request: .init(name: "available", expectedHead: plan.head, allowUncommittedChanges: true))
            #expect(newPath == plan.directory(name: "available") + "/src folder")
            #expect(try await fixture.git(["branch", "--show-current"], at: newPath) == "available")
        }
    }

    @Test("An untracked source subdirectory absent from HEAD reports and retains the created worktree")
    func missingSubdirectory() async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let source = fixture.root.appendingPathComponent("untracked folder")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "only here".write(to: source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            let manager = AgentForkWorktreeManager()
            let plan = try await manager.inspect(source.path)
            let path = plan.directory(name: "retained")
            do {
                _ = try await manager.create(source.path, request: .init(name: "retained", expectedHead: plan.head, allowUncommittedChanges: true))
                Issue.record("Missing cwd must fail rather than silently launch at the repository root")
            } catch { #expect(error.localizedDescription.contains(path)) }
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try await fixture.git(["branch", "--show-current"], at: path) == "retained")
        }
    }

    @MainActor
    @Test("Real Git/tmux Fork ignores custom shell defaults and never leaks config roots", arguments: ["codex", "claude-code", "claude-default"], [
        (worktree: false, overwriteRoot: false),
        (worktree: false, overwriteRoot: true),
        (worktree: true, overwriteRoot: false),
        (worktree: true, overwriteRoot: true),
    ])
    func nativeLaunchPlumbing(pluginID: String, mode: (worktree: Bool, overwriteRoot: Bool)) async throws {
        try await live {
            let fixture = try await ForkGitFixture.make()
            defer { try? fixture.cleanUp() }
            let socket = fixture.container.appendingPathComponent("tmux.sock").path
            let tmuxPath = try #require(TmuxBinaryLocator.liveValue.find())
            let runner = ProcessRunner.liveValue
            let shellConfiguration = """
            HISTFILE=/dev/null
            SAVEHIST=0
            \(mode.overwriteRoot ? "export CODEX_HOME='/wrong codex root'\nexport CLAUDE_CONFIG_DIR='/wrong claude root'" : "")
            PROMPT='FORK_READY> '
            """
            try shellConfiguration.write(to: fixture.container.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            // An argv/cwd probe, not an Agent or model call. Exercise the native
            // builders and actual tmux/Git without touching real conversations.
            let executable = fixture.container.appendingPathComponent("agent probe")
            try """
            #!/bin/sh
            prefix=FORK
            if [ "$1" = normal ]; then prefix=NORMAL; fi
            printf 'FORK_CWD[%s]\\n' "$PWD"
            printf 'FORK_ARG[%s]\\n' "$@"
            printf '%s_CONFIG[%s]\\n' "$prefix" "$(if [ "$FORK_TEST_AGENT" = codex ]; then printf '%s' "${CODEX_HOME-UNSET}"; else printf '%s' "${CLAUDE_CONFIG_DIR-UNSET}"; fi)"
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            // Exercise a tcsh default-shell without sourcing user startup files.
            let defaultShell = fixture.container.appendingPathComponent("tcsh")
            try "#!/bin/sh\nexec /bin/tcsh -f \"$@\"\n".write(to: defaultShell, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: defaultShell.path)
            let core: any AgentSessionForking
            if pluginID == "codex" {
                let codex = CodexPluginCore()
                _ = await codex.applySettings(try JSONEncoder().encode(CodexSettings(commandPath: executable.path, autoRun: false, exportTelemetry: false)))
                core = codex
            } else {
                let claude = ClaudeCodePluginCore()
                _ = await claude.applySettings(try JSONEncoder().encode(ClaudeCodeSettings(commandPath: executable.path, autoRun: false)))
                core = claude
            }
            do {
                try await withDependencies {
                    $0[AgentForkHistoryClient.self].root = { _, _, _ in
                        pluginID == "claude-default"
                            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").resolvingSymlinksInPath().path
                            : fixture.container.path
                    }
                    $0[AgentForkWorktreeClient.self] = .liveValue
                } operation: {
                    let tmux = TmuxService(tmuxPath: tmuxPath, socketPath: socket)
                    tmux.zdotDirOverride = fixture.container.path
                    let original = try await tmux.createSession(baseName: "fork-test", width: 240, height: 24, workingDirectory: fixture.source)
                    // Only this isolated server is changed. A clean inherited
                    // environment exposes leaks that rc overrides would mask.
                    for variable in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
                        let reset = try await runner.run(tmuxPath, [
                            "-S", socket, "set-environment", "-gu", variable,
                            ";", "set-environment", "-u", "-t", original.sessionName, variable,
                        ], nil, nil)
                        #expect(reset.isSuccess)
                    }
                    let defaults = try await runner.run(tmuxPath, [
                        "-S", socket, "set-option", "-t", original.sessionName, "default-shell", defaultShell.path,
                        ";", "set-option", "-t", original.sessionName, "default-command", "exec /bin/tcsh -f",
                    ], nil, nil)
                    #expect(defaults.isSuccess)
                    let source = try #require(AgentForkSource(pane: PaneState(
                        paneId: original.paneId, sessionName: original.sessionName, tmuxWindowId: "@0", currentPath: fixture.source,
                        agentSession: .init(paneId: original.paneId, pluginID: pluginID == "codex" ? "codex" : "claude-code"), claudeSessionID: UUID().uuidString
                    )))
                    let service = AgentForkService(
                        source: { $0 == source.paneID ? source : nil }, core: { _ in core },
                        refresh: { _ = await tmux.refreshPanes() },
                        launch: { session, name, prepared in
                            try await tmux.newWindow(sessionName: session, workingDirectory: prepared.workingDirectory,
                                windowName: name, runCommand: prepared.forkRunCommand(shell: tmux.loginShellPath),
                                extraEnvironment: prepared.extraEnvironment + ["FORK_TEST_AGENT=\(pluginID)"], forceLoginShell: true)
                        }
                    )
                    let plan = try await service.prepare(source)
                    let worktree = mode.worktree ? ForkAgentSession.Worktree(name: "probe", expectedHead: try #require(plan.worktree).head) : nil
                    let name = mode.worktree ? "probe" : "我的 Fork probe"
                    let request = ForkAgentSession(source: source, windowName: name, worktree: worktree)
                    let paneID = try await service.fork(request)
                    #expect(try await service.fork(request) == paneID)
                    let expectedDirectory = mode.worktree ? fixture.root.path + "/.worktrees/probe/src folder" : fixture.source
                    var screen = ""
                    for _ in 0..<30 {
                        screen = try await tmux.capturePaneText(paneID)
                        if screen.contains("FORK_CONFIG[") { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    #expect(screen.contains("FORK_CWD[\(expectedDirectory)]"))
                    #expect(screen.contains("FORK_ARG[\(source.sessionID)]"))
                    let expectedConfig = pluginID == "claude-default" ? "UNSET" : fixture.container.path
                    #expect(screen.contains("FORK_CONFIG[\(expectedConfig)]"))
                    let windowName = try await runner.runOrThrow(executable: tmuxPath, arguments: [
                        "-S", socket, "display-message", "-p", "-t", paneID, "#{window_name}",
                    ])
                    #expect(windowName.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == name)
                    if pluginID == "codex" {
                        #expect(screen.contains("FORK_ARG[fork]"))
                        #expect(screen.contains("FORK_ARG[-C]"))
                    } else {
                        #expect(screen.contains("FORK_ARG[--resume]"))
                        #expect(screen.contains("FORK_ARG[--fork-session]"))
                    }
                    let nextLaunch = """
                    \(executable.path.posixSingleQuoted) normal; printf 'PARENT_CODEX[%s]PARENT_CLAUDE[%s]\\n' "${CODEX_HOME-UNSET}" "${CLAUDE_CONFIG_DIR-UNSET}"
                    """
                    let normalCodexRoot = mode.overwriteRoot ? "/wrong codex root" : "UNSET"
                    let normalClaudeRoot = mode.overwriteRoot ? "/wrong claude root" : "UNSET"
                    let expectedParent = "PARENT_CODEX[\(normalCodexRoot)]PARENT_CLAUDE[\(normalClaudeRoot)]"
                    let sent = try await runner.run(tmuxPath, ["-S", socket, "send-keys", "-t", paneID, nextLaunch, "Enter"], nil, nil)
                    #expect(sent.isSuccess)
                    for _ in 0..<30 {
                        screen = try await tmux.capturePaneText(paneID)
                        if screen.contains("NORMAL_CONFIG["), screen.contains(expectedParent) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    #expect(screen.contains("NORMAL_CONFIG[\(pluginID == "codex" ? normalCodexRoot : normalClaudeRoot)]"))
                    #expect(screen.contains(expectedParent))
                    let panes = await tmux.refreshPanes()
                    #expect(panes.count == 2)
                    #expect(panes.contains { $0.paneId == original.paneId })
                    let originalScreen = try await tmux.capturePaneText(original.paneId)
                    #expect(!originalScreen.contains("FORK_CWD["))
                    // Ordinary Terminal must still honor the session's tcsh
                    // default; forcing the Host shell is specific to Fork.
                    let ordinaryPane = try await tmux.newWindow(sessionName: original.sessionName, windowName: "ordinary terminal")
                    var ordinaryCommand = ""
                    for _ in 0..<30 {
                        let result = try await runner.run(tmuxPath, ["-S", socket, "display-message", "-p", "-t", ordinaryPane, "#{pane_current_command}"], nil, nil)
                        ordinaryCommand = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                        if ordinaryCommand == "tcsh" { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    #expect(ordinaryCommand == "tcsh")
                    // Closing the fork tab must not delete the checkout.
                    if mode.worktree {
                        let windowID = try #require(tmux.windows.first(where: { $0.panes.contains { $0.paneId == paneID } })?.stableId)
                        try await tmux.killWindow(windowID)
                        #expect(FileManager.default.fileExists(atPath: expectedDirectory))
                    }
                }
            } catch {
                await core.shutdown()
                _ = try? await runner.run(tmuxPath, ["-S", socket, "kill-server"], nil, nil)
                throw error
            }
            await core.shutdown()
            let cleanup = try await runner.run(tmuxPath, ["-S", socket, "kill-server"], nil, nil)
            #expect(cleanup.isSuccess)
        }
    }
}
