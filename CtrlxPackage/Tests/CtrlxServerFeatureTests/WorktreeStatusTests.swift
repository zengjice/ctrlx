import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorktreeStatusTests {
    @Test("Visible Git tabs are monitored even without a terminal in their repository")
    func gitTabDiscovery() async {
        let queried = LockIsolated(Set<String>())
        await withDependencies {
            $0[WorktreeStatusClient.self].refresh = { paths in
                queried.setValue(Set(paths))
                return .init(locations: Dictionary(uniqueKeysWithValues: paths.map { ($0, .init(root: $0, branch: "main")) }))
            }
        } operation: {
            let manager = makeManager()
            let first = UUID(), second = UUID()
            manager.trackGitDirectory("/git-only", for: first)
            manager.trackGitDirectory("/git-only", for: second)
            await manager.refreshGitBranches()
            #expect(queried.value == ["/git-only"])
            #expect(manager.gitWorktreePathsByDirectory["/git-only"] == "/git-only")
            manager.trackGitDirectory(nil, for: first)
            await manager.refreshGitBranches()
            #expect(queried.value == ["/git-only"])
            manager.trackGitDirectory(nil, for: second)
            await manager.refreshGitBranches()
            #expect(queried.value.isEmpty)
            #expect(manager.gitWorktreePathsByDirectory.isEmpty)
        }
    }

    @Test("A main-only change publishes to Viewers; unchanged counts do not republish")
    func publishing() async {
        let current = LockIsolated(WorktreeStatusRefresh(
            locations: ["/repo/ux": .init(root: "/repo/ux", branch: "ux")],
            repositories: [.init(id: "/repo/.git", worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 1)])]
        ))
        await withDependencies {
            $0[WorktreeStatusClient.self].refresh = { _ in current.value }
        } operation: {
            let manager = makeManager()
            manager.updatePaneStates(from: [pane(path: "/repo/ux")])
            var pushes = 0
            manager.onSessionMetadataChanged = { pushes += 1 }
            await manager.refreshGitBranches()
            #expect(manager.paneStates["%5"]?.gitWorktreePath == "/repo/ux")
            #expect(pushes == 1)
            await manager.refreshGitBranches()
            #expect(pushes == 1)
            current.withValue { value in
                value.repositories = [.init(id: "/repo/.git", worktrees: [.init(path: "/repo/ux", branch: "ux", pendingCommitCount: 0)])]
            }
            await manager.refreshGitBranches()
            #expect(pushes == 2)
            #expect(manager.worktreeRepositories.first?.worktrees.first?.pendingCommitCount == 0)
            manager.updatePaneStates(from: [pane(path: "/not-git")])
            #expect(manager.paneStates["%5"]?.gitWorktreePath == nil)
        }
    }

    @Test("An in-flight Git result cannot overwrite a pane's newer path or agent state")
    func staleRefresh() async {
        let started = AsyncStream<Void>.makeStream()
        let completion = LockIsolated<CheckedContinuation<WorktreeStatusRefresh, Never>?>(nil)
        await withDependencies {
            $0[WorktreeStatusClient.self].refresh = { _ in
                await withCheckedContinuation { continuation in
                    completion.setValue(continuation)
                    started.continuation.yield(())
                }
            }
        } operation: {
            let manager = makeManager()
            manager.updatePaneStates(from: [pane(path: "/old")])
            let refresh = Task { await manager.refreshGitBranches() }
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
            manager.updatePaneStates(from: [pane(path: "/new")])
            manager.applyState(pluginID: "codex", sessionID: "session", state: .working, tmuxPane: "%5", projectPath: "/new")
            completion.value?.resume(returning: .init(locations: ["/old": .init(root: "/old", branch: "old")]))
            await refresh.value
            #expect(manager.paneStates["%5"]?.gitWorktreePath == nil)
            #expect(manager.paneStates["%5"]?.currentPath == "/new")
            #expect(manager.paneStates["%5"]?.agentSession?.state == .working)
        }
    }

    private func makeManager() -> MirrorWindowManager {
        withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[ProcessRunner.self] = .previewValue
            $0[LoginItemService.self] = .previewValue
        } operation: {
            let tmux = TmuxService()
            return MirrorWindowManager(
                settings: AppSettings(), tmuxService: tmux,
                paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                editorSessionManager: EditorSessionManager()
            )
        }
    }

    private func pane(path: String) -> PaneInfo {
        PaneInfo(paneId: "%5", target: "work:0.0", sessionName: "work", windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: path, width: 80, height: 24, isActive: true)
    }

    @Test("All valid worktrees, including inactive ones, update after commits and main merges")
    func realRepository() async throws {
        let commands = LockIsolated([[String]]())
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                commands.withValue { $0.append(arguments) }
                return try await ProcessRunner.liveValue.run(executable, arguments, environment, timeout)
            }
        } operation: {
            let fixture = try await WorktreeGitFixture.make()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let feature = fixture.root.appendingPathComponent("feature worktree").path
            let inactive = fixture.root.appendingPathComponent("inactive worktree").path
            _ = try await fixture.git(["worktree", "add", "-b", "feature", feature])
            _ = try await fixture.git(["worktree", "add", "-b", "inactive", inactive])
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "feature change"], at: feature)
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "inactive change"], at: inactive)
            let reader = WorktreeStatusReader()
            let paths = [fixture.repo.path, feature, feature]
            let first = await reader.refresh(paths: paths)
            #expect(first.repositories.count == 1)
            #expect(first.repositories.first?.worktrees.count == 3)
            #expect(first.entry("feature")?.pendingCommitCount == 1)
            #expect(first.entry("inactive")?.pendingCommitCount == 1)
            #expect(first.locations[feature]?.branch == "feature")
            let comparisons = commands.value.filter { $0.contains("rev-list") }.count
            let lists = commands.value.filter { $0.contains("list") }.count
            _ = await reader.refresh(paths: paths)
            #expect(commands.value.filter { $0.contains("rev-list") }.count == comparisons)
            #expect(commands.value.filter { $0.contains("list") }.count == lists + 1)

            try "dirty".write(toFile: feature + "/untracked.txt", atomically: true, encoding: .utf8)
            #expect(await reader.refresh(paths: paths).entry("feature")?.pendingCommitCount == 1)
            _ = try await fixture.git(["merge", "--no-ff", "feature", "-m", "merge feature"])
            let merged = await reader.refresh(paths: paths)
            #expect(merged.entry("feature")?.pendingCommitCount == 0)
            #expect(merged.entry("inactive")?.pendingCommitCount == 1)
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "next feature change"], at: feature)
            #expect(await reader.refresh(paths: paths).entry("feature")?.pendingCommitCount == 1)

            // A removed directory can retain a prunable Git record.
            try FileManager.default.removeItem(atPath: inactive)
            #expect(await reader.refresh(paths: paths).entry("inactive") == nil)
            _ = try await fixture.git(["checkout", "--detach"], at: feature)
            let detached = await reader.refresh(paths: paths)
            #expect(detached.locations[feature]?.branch == "(detached)")
            #expect(detached.repositories.flatMap(\.worktrees).first { $0.path == feature }?.unavailableReason != nil)
        }
    }

    @Test("Submodules use their actual checkout for branch names and merge badges, even when discovered from a linked worktree")
    func submoduleWorktrees() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let parent = try await WorktreeGitFixture.make()
            defer { try? FileManager.default.removeItem(at: parent.root) }
            let source = try await WorktreeGitFixture.make()
            defer { try? FileManager.default.removeItem(at: source.root) }
            try FileManager.default.createDirectory(at: source.repo.appendingPathComponent("src"), withIntermediateDirectories: true)
            try "fixture".write(to: source.repo.appendingPathComponent("src/file.txt"), atomically: true, encoding: .utf8)
            _ = try await source.git(["add", "src/file.txt"])
            _ = try await source.git(["commit", "-m", "source files"])
            _ = try await parent.git(["-c", "protocol.file.allow=always", "submodule", "add", source.repo.path, "sub module"])
            let submodule = parent.repo.appendingPathComponent("sub module").path
            let subdirectory = submodule + "/src"
            _ = try await parent.git(["config", "user.name", "CtrlX Test"], at: submodule)
            _ = try await parent.git(["config", "user.email", "test@example.invalid"], at: submodule)
            _ = try await parent.git(["config", "core.hooksPath", "/dev/null"], at: submodule)
            _ = try await parent.git(["config", "commit.gpgSign", "false"], at: submodule)
            _ = try await parent.git(["checkout", "-b", "feature"], at: submodule)
            _ = try await parent.git(["commit", "--allow-empty", "-m", "feature change"], at: submodule)
            let linked = parent.root.appendingPathComponent("linked worktree").path
            _ = try await parent.git(["worktree", "add", "-b", "linked", linked, "main"], at: submodule)
            _ = try await parent.git(["commit", "--allow-empty", "-m", "linked change"], at: linked)

            for paths in [[submodule], [subdirectory], [linked], [subdirectory, linked]] {
                // A fresh reader proves linked-only discovery does not rely on
                // having previously observed the submodule's primary checkout.
                let result = await WorktreeStatusReader().refresh(paths: paths)
                #expect(result.repositories.count == 1)
                #expect(result.repositories.first?.worktrees.count == 2)
                #expect(result.entry("feature")?.path == submodule)
                #expect(result.entry("feature")?.pendingCommitCount == 1)
                #expect(result.entry("linked")?.path == linked)
                #expect(result.entry("linked")?.pendingCommitCount == 1)
                for path in paths {
                    let expectedRoot = path == linked ? linked : submodule
                    let expectedBranch = path == linked ? "linked" : "feature"
                    #expect(result.locations[path]?.root == expectedRoot)
                    #expect(result.locations[path]?.branch == expectedBranch)
                    let selection = WorktreeStatusSelection(repositories: result.repositories, paths: [expectedRoot])
                    #expect(selection.badgeText == "\(expectedBranch) · 1 to main")
                }
            }

            _ = try await parent.git(["checkout", "main"], at: linked)
            _ = try await parent.git(["merge", "--ff-only", "feature"], at: linked)
            let merged = await WorktreeStatusReader().refresh(paths: [subdirectory, linked])
            #expect(merged.locations[subdirectory]?.branch == "feature")
            #expect(merged.entry("feature")?.path == submodule)
            #expect(merged.entry("feature")?.pendingCommitCount == 0)
            #expect(WorktreeStatusSelection(repositories: merged.repositories, paths: [submodule]).badgeText == nil)
        }
    }

    @Test("Separate Git directories preserve observed checkouts and isolate an unresolved primary worktree")
    func separateGitDirectoryWorktrees() async throws {
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[ProcessRunner.self] = .liveValue
        } operation: {
            let fixture = try await WorktreeGitFixture.make(separateGitDirectory: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let primary = fixture.repo.path
            let metadata = fixture.root.appendingPathComponent("metadata").path
            let subdirectory = primary + "/src"
            try FileManager.default.createDirectory(atPath: subdirectory, withIntermediateDirectories: true)
            _ = try await fixture.git(["checkout", "-b", "feature"])
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "feature change"])
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "another feature change"])
            let linked = fixture.root.appendingPathComponent("linked worktree").path
            _ = try await fixture.git(["worktree", "add", "-b", "linked", linked, "main"])
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "linked change"], at: linked)

            let reader = WorktreeStatusReader()
            // No reverse pointer exists for the primary checkout. A linked
            // checkout must not be mistaken for it just because it is observed.
            let linkedOnly = await reader.refresh(paths: [linked])
            #expect(linkedOnly.repositories.count == 1)
            #expect(linkedOnly.repositories.first?.unavailableReason == nil)
            #expect(linkedOnly.repositories.first?.worktrees.count == 2)
            #expect(linkedOnly.entry("feature")?.path == metadata)
            #expect(linkedOnly.entry("feature")?.pendingCommitCount == nil)
            #expect(linkedOnly.entry("feature")?.unavailableReason != nil)
            #expect(linkedOnly.entry("linked")?.path == linked)
            #expect(linkedOnly.entry("linked")?.pendingCommitCount == 1)
            #expect(linkedOnly.locations[linked]?.branch == "linked")
            let linkedSelection = WorktreeStatusSelection(repositories: linkedOnly.repositories, paths: [linked])
            #expect(linkedSelection.badgeText == "linked · 1 to main")
            #expect(!linkedSelection.hasUnavailableStatus)

            for paths in [[primary], [subdirectory], [subdirectory, linked]] {
                let result = await reader.refresh(paths: paths)
                #expect(result.repositories.count == 1)
                #expect(result.repositories.first?.id == metadata)
                #expect(result.repositories.first?.unavailableReason == nil)
                #expect(result.repositories.first?.worktrees.count == 2)
                #expect(result.entry("feature")?.path == primary)
                #expect(result.entry("feature")?.pendingCommitCount == 2)
                #expect(result.entry("feature")?.unavailableReason == nil)
                #expect(result.entry("linked")?.path == linked)
                #expect(result.entry("linked")?.pendingCommitCount == 1)
                for path in paths {
                    let expectedRoot = path == linked ? linked : primary
                    let expectedBranch = path == linked ? "linked" : "feature"
                    let expectedCount = path == linked ? 1 : 2
                    #expect(result.locations[path]?.root == expectedRoot)
                    #expect(result.locations[path]?.branch == expectedBranch)
                    let selection = WorktreeStatusSelection(repositories: result.repositories, paths: [expectedRoot])
                    #expect(selection.badgeText == "\(expectedBranch) · \(expectedCount) to main")
                }
            }

            try FileManager.default.removeItem(at: fixture.repo)
            let missing = await reader.refresh(paths: [primary, linked])
            #expect(missing.locations[primary] == nil)
            #expect(missing.repositories.first?.unavailableReason == nil)
            #expect(missing.entry("feature")?.pendingCommitCount == nil)
            #expect(missing.entry("feature")?.unavailableReason != nil)
            #expect(missing.locations[linked]?.branch == "linked")
            #expect(missing.entry("linked")?.pendingCommitCount == 1)
        }
    }

    @Test("Missing local main and Git failures never become zero pending commits")
    func unavailable() async throws {
        let failComparison = LockIsolated(false)
        try await withDependencies {
            $0.continuousClock = ContinuousClock()
            $0[ProcessRunner.self].run = { executable, arguments, environment, timeout in
                if failComparison.value, arguments.contains("rev-list") {
                    return .init(exitCode: 1, stdout: Data(), stderr: Data("fixture failure".utf8))
                }
                return try await ProcessRunner.liveValue.run(executable, arguments, environment, timeout)
            }
        } operation: {
            let fixture = try await WorktreeGitFixture.make()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try await fixture.git(["branch", "-m", "trunk"])
            let reader = WorktreeStatusReader()
            let missing = await reader.refresh(paths: [fixture.repo.path])
            #expect(missing.entry("trunk")?.pendingCommitCount == nil)
            #expect(missing.entry("trunk")?.unavailableReason != nil)
            _ = try await fixture.git(["branch", "main"])
            failComparison.setValue(true)
            let failed = await reader.refresh(paths: [fixture.repo.path])
            #expect(failed.entry("trunk")?.pendingCommitCount == nil)
            #expect(failed.entry("trunk")?.unavailableReason?.contains("fixture failure") == true)
            failComparison.setValue(false)
            #expect(await reader.refresh(paths: [fixture.repo.path]).entry("trunk")?.pendingCommitCount == 0)
            #expect(await reader.refresh(paths: [fixture.root.path]).repositories.isEmpty)
        }
    }

    @Test("NUL worktree records preserve path characters and detached/prunable state")
    func porcelain() {
        let entries = WorktreeStatusReader.parse("worktree /repo with space\nline\0HEAD abc\0branch refs/heads/feature/topic\0\0worktree /gone\0HEAD def\0detached\0prunable missing gitdir\0\0")
        #expect(entries.count == 2)
        #expect(entries[0].path == "/repo with space\nline")
        #expect(entries[0].branch == "feature/topic")
        #expect(entries[1].branch == nil)
        #expect(entries[1].prunable)
    }
}

private extension WorktreeStatusRefresh {
    func entry(_ branch: String) -> WorktreeMergeStatus? {
        repositories.flatMap(\.worktrees).first { $0.branch == branch }
    }
}

private struct WorktreeGitFixture {
    let root: URL
    var repo: URL {
        root.appendingPathComponent("repo")
    }

    static func make(separateGitDirectory: Bool = false) async throws -> Self {
        let fixture = Self(root: FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-worktree-test-\(UUID())").resolvingSymlinksInPath())
        try FileManager.default.createDirectory(at: fixture.repo, withIntermediateDirectories: true)
        var arguments = ["init", "--initial-branch=main"]
        if separateGitDirectory {
            arguments += ["--separate-git-dir", fixture.root.appendingPathComponent("metadata").path]
        }
        _ = try await fixture.git(arguments)
        _ = try await fixture.git(["config", "user.name", "CtrlX Test"])
        _ = try await fixture.git(["config", "user.email", "test@example.invalid"])
        _ = try await fixture.git(["config", "core.hooksPath", "/dev/null"])
        _ = try await fixture.git(["config", "commit.gpgSign", "false"])
        _ = try await fixture.git(["commit", "--allow-empty", "-m", "initial"])
        return fixture
    }

    func git(_ arguments: [String], at directory: String? = nil) async throws -> String {
        let result = try await ProcessRunner.liveValue.runOrThrow(executable: "/usr/bin/git", arguments: ["-C", directory ?? repo.path] + arguments)
        return result.stdoutString
    }
}
