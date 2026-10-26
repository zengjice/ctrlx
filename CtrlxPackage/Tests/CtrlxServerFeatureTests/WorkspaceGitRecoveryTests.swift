import AppKit
import CtrlxCommon
import Dependencies
import Foundation
import GitWorkbench
import GitWorkbenchGitKit
import Testing
@testable import CtrlxServerFeature

@MainActor
struct WorkspaceGitRecoveryTests {
    private struct Repository {
        let url: URL

        func git(_ args: [String]) async throws -> String {
            try await ProcessRunner.liveValue.runOrThrow(
                executable: "/usr/bin/git", arguments: ["-C", url.path] + args,
                environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"], timeout: 10
            ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func write(_ text: String, path: String = "note.txt") throws {
            try text.write(to: url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        @MainActor
        func entry(_ recovery: WorkspaceGitState? = nil) -> GitStoreEntry {
            GitStoreEntry(
                path: url.path,
                provider: WorkspaceGitProvider.live(base: CLIGitProvider(repositoryURL: url), directory: url.path),
                configuration: .init(), recovery: recovery
            )
        }
    }

    private func withRepository(_ operation: (Repository) async throws -> Void) async throws {
        let url = URL(fileURLWithPath: "/tmp/ctrlx-git-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let repo = Repository(url: url)
            _ = try await repo.git(["init", "-b", "main"])
            _ = try await repo.git(["config", "user.name", "Recovery Test"])
            _ = try await repo.git(["config", "user.email", "recovery@example.invalid"])
            _ = try await repo.git(["config", "commit.gpgsign", "false"])
            try repo.write("original\n")
            _ = try await repo.git(["add", "."])
            _ = try await repo.git(["commit", "-qm", "initial"])
            try await operation(repo)
        }
    }

    @Test("Changes selection distinguishes staged and unstaged copies and never submits the draft")
    func changes() async throws {
        try await withRepository { repo in
            try repo.write("staged\n")
            _ = try await repo.git(["add", "."])
            try repo.write("unstaged\n")
            let original = repo.entry()
            await original.load()
            let selected = try #require(original.store.state.repo.files.first { $0.path == "note.txt" && $0.isStaged })
            original.store.select(file: selected.id)
            original.store.setCommitMessage("Unsent commit draft\nwith details")
            let saved = try JSONDecoder().decode(WorkspaceGitState.self, from: JSONEncoder().encode(original.snapshot))
            let head = try await repo.git(["rev-parse", "HEAD"])
            let index = try await repo.git(["write-tree"])
            let restored = repo.entry(saved)
            #expect(restored.snapshot == saved)
            await restored.load()
            #expect(restored.pendingRecovery == nil && restored.recoveryIssue == nil)
            #expect(restored.snapshot == saved)
            #expect(restored.store.state.pendingDiscard == nil && restored.store.state.pendingHardReset == nil)
            #expect(try await repo.git(["rev-parse", "HEAD"]) == head)
            #expect(try await repo.git(["write-tree"]) == index)
            restored.store.setCommitMessage("new text")
            await restored.load()
            #expect(restored.snapshot.commitMessage == "new text")
        }
    }

    @Test("Moving a session restores the live Git selection and latest draft in both directions", arguments: [false, true])
    func sessionWindowRoundTrip(mainSelectedAnotherSession: Bool) async throws {
        try await withRepository { repo in
            _ = NSApplication.shared
            try repo.write("changed\n")
            let original = repo.entry()
            await original.load()
            try original.store.select(file: #require(original.store.state.repo.files.first).id)
            original.store.setCommitMessage("main window draft")
            let saved = original.snapshot
            let head = try await repo.git(["rev-parse", "HEAD"])
            let windows = DetachedTerminalWindows()
            let tabs = windows.mainTabs.tabs(hostID: nil, session: "work")
            tabs.tabOrder = [.window("@1"), .git]
            tabs.isGitSelected = true
            windows.mainTabs.capturePresentation = {
                windows.mainTabs.recordGitState(original.snapshot, for: "work")
            }
            defer { windows.mainTabs.capturePresentation = nil }
            #expect(windows.mainTabs.pendingGitRecoverySessions.isEmpty)

            let group = try #require(windows.detachSession(hostID: nil, name: "work", windowIDs: ["@1"], selectedWindowID: "@1", position: nil, session: { _ in "work" }))
            let detachedRecovery = try #require(group.tabs.takeGitRecovery(for: "work"))
            let detached = repo.entry(detachedRecovery)
            await detached.load()
            #expect(detached.snapshot == saved)
            #expect(group.tabs.takeGitRecovery(for: "work") == nil)
            #expect(group.tabs.local["work"]?.isGitSelected == true)
            detached.store.setCommitMessage("edited in detached window")
            group.tabs.capturePresentation = {
                group.tabs.recordGitState(detached.snapshot, for: "work")
            }
            defer { group.tabs.capturePresentation = nil }
            windows.mainTabs.recoverySelection = .init(sessionName: mainSelectedAnotherSession ? "other" : "work", windowID: mainSelectedAnotherSession ? "@9" : "@1")
            let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.attach(window, toWorkspace: group.id)
            window.close()

            windows.mainTabs.capturePresentation?()
            let returnedRecovery = try #require(windows.mainTabs.takeGitRecovery(for: "work"))
            let returned = repo.entry(returnedRecovery)
            await returned.load()
            #expect(returned.snapshot == detached.snapshot)
            #expect(returned.store.state.commitMessage == "edited in detached window")
            #expect(windows.mainTabs.takeGitRecovery(for: "work") == nil)
            #expect(windows.mainTabs.local["work"]?.isGitSelected == true)
            #expect(try await repo.git(["rev-parse", "HEAD"]) == head)
        }
    }

    @Test("An older exact commit remains selectable after it falls outside the first history page")
    func oldHistory() async throws {
        try await withRepository { repo in
            _ = try await repo.git(["branch", "topic"])
            let original = repo.entry()
            await original.load()
            let branch = try #require(original.store.state.branches.first { $0.name == "topic" })
            await original.store.showHistory(of: branch)
            let commit = try #require(original.store.state.commits.first)
            await original.store.selectCommit(commit.id)
            let saved = original.snapshot
            // Advance topic without checking it out; the workbench must never switch HEAD.
            let tree = try await repo.git(["rev-parse", "HEAD^{tree}"])
            var parent = commit.id
            for index in 0..<51 {
                parent = try await repo.git(["commit-tree", tree, "-p", parent, "-m", "later \(index)"])
            }
            _ = try await repo.git(["update-ref", "refs/heads/topic", parent])
            let restored = repo.entry(saved)
            await restored.load()
            #expect(restored.recoveryIssue == nil && restored.pendingRecovery == nil)
            #expect(restored.store.state.activeView == .history)
            #expect(restored.store.state.historyBranch == "topic")
            #expect(restored.store.state.selectedCommitID == commit.id)
            #expect(restored.snapshot.commitFile == saved.commitFile)
            #expect(try await repo.git(["branch", "--show-current"]) == "main")
            #expect(try await repo.git(["rev-parse", "HEAD"]) == commit.id)
        }
    }

    @Test("Stash ordinal reuse restores the same object; a removed Stash remains unavailable")
    func stashIdentity() async throws {
        try await withRepository { repo in
            try repo.write("saved stash\n")
            _ = try await repo.git(["stash", "push", "-m", "original"])
            let original = repo.entry()
            await original.load()
            let stash = try #require(original.store.state.stashes.first)
            #expect(WorkspaceGitProvider.isObjectID(stash.id))
            original.store.select(.stashes)
            await original.store.selectStash(stash.id)
            let saved = original.snapshot
            try repo.write("new stash\n")
            _ = try await repo.git(["stash", "push", "-m", "new"])
            let restored = repo.entry(saved)
            await restored.load()
            #expect(restored.pendingRecovery == nil && restored.recoveryIssue == nil)
            #expect(restored.store.state.selectedStashID == stash.id)
            #expect(restored.store.state.stashes.first { $0.id == stash.id }?.ref == "stash@{1}")
            _ = try await repo.git(["stash", "drop", "stash@{1}"])
            let missing = repo.entry(saved)
            await missing.load()
            #expect(missing.recoveryIssue?.contains("Stash is unavailable") == true)
            #expect(missing.snapshot == saved)
            #expect(missing.store.state.selectedStashID == nil)
            #expect(try await repo.git(["status", "--porcelain"]) == "")
        }
    }

    @Test("A missing selected change preserves the draft and can be retried or explicitly dismissed")
    func missingChange() async throws {
        try await withRepository { repo in
            try repo.write("changed\n")
            let original = repo.entry()
            await original.load()
            try original.store.select(file: #require(original.store.state.repo.files.first).id)
            original.store.setCommitMessage("keep this draft")
            let saved = original.snapshot
            try repo.write("original\n")
            let missing = repo.entry(saved)
            await missing.load()
            #expect(missing.recoveryIssue?.contains("note.txt") == true)
            #expect(missing.snapshot == saved)
            try repo.write("changed again\n")
            await missing.load()
            #expect(missing.recoveryIssue == nil && missing.pendingRecovery == nil)
            #expect(missing.store.state.commitMessage == saved.commitMessage)

            let dismissed = repo.entry(saved)
            dismissed.store.setCommitMessage("edited draft")
            dismissed.openWithoutSavedSelection()
            await dismissed.load()
            #expect(dismissed.pendingRecovery == nil)
            #expect(dismissed.store.state.commitMessage == "edited draft")
            #expect(dismissed.store.state.selectedFileID == nil)
        }
    }

    @Test("Scene restoration keeps separate Git previews and drafts for sessions in the same directory")
    func sceneIdentity() async throws {
        try await withRepository { repo in
            let entry = repo.entry()
            await entry.load()
            entry.store.setCommitMessage("first")
            let first = entry.snapshot
            entry.store.setCommitMessage("second")
            let second = entry.snapshot
            var a = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
            var b = WorkspaceRecoveryStoreTests.snapshot().sessions[0]
            a.name = "one"
            b.name = "two"
            b.windows[0].runtimeID = "@2"
            var backingWindow = WorkspaceRecoveryStoreTests.snapshot().sessions[0].windows[0]
            backingWindow.runtimeID = "@3"
            backingWindow.index = 1
            a.windows.append(backingWindow)
            let windows = DetachedTerminalWindows()
            windows.mainTabs.recoveryGitStates = [a.name: first, b.name: second]
            windows.mainTabs.recoverySelection = .init(hostID: nil, sessionName: a.name, windowID: backingWindow.runtimeID)
            windows.mainTabs.tabs(hostID: nil, session: a.name).isGitSelected = true
            let scenes = WorkspaceRecoveryPresentationMapper.captureLocal(windows: windows, sessions: [a, b], mainID: windows.mainSceneID)
            a.name = "renamed"
            a.windows[1].runtimeID = "@10"
            let restored = DetachedTerminalWindows()
            WorkspaceRecoveryPresentationMapper.restoreLocal(scenes, live: .init(serverID: "new", sessions: [a, b]), windows: restored, files: [])
            #expect(restored.mainTabs.recoveryGitStates[a.name] == first)
            #expect(restored.mainTabs.recoveryGitStates[b.name] == second)
            #expect(restored.mainTabs.restoredSelection?.windowID == "@10")
            #expect(restored.mainTabs.local[a.name]?.isGitSelected == true)
            #expect(restored.mainTabs.takeGitRecovery(for: a.name) == first)
            #expect(restored.mainTabs.takeGitRecovery(for: a.name) == nil)
            restored.mainTabs.recoveryGitStates[a.name]?.commitMessage = "edited"
            WorkspaceRecoveryPresentationMapper.restoreLocal(scenes, live: .init(serverID: "new", sessions: [a, b]), windows: restored, files: [])
            #expect(restored.mainTabs.recoveryGitStates[a.name]?.commitMessage == "edited")
            #expect(restored.mainTabs.takeGitRecovery(for: a.name) == nil)
        }
    }

    private actor LoadGate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !started else { return }
            started = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("Concurrent badge/view loads share restoration even when one caller disappears")
    func sharedLoad() async throws {
        let mock = MockGitProvider(delay: .zero)
        let gate = LoadGate()
        let stashes = try await mock.loadStashes()
        let mapping = Dictionary(uniqueKeysWithValues: stashes.enumerated().map { ($0.element.ref, String(repeating: String($0.offset + 1), count: 40)) })
        let provider = WorkspaceGitProvider(base: mock, stashIdentities: {
            await gate.wait()
            return mapping
        })
        let seed = GitWorkbenchStore(provider: mock)
        seed.setCommitMessage("shared unsent draft")
        let saved = WorkspaceGitState(directory: "/fixture", store: seed)
        let entry = GitStoreEntry(path: "/fixture", provider: provider, configuration: .init(), recovery: saved)
        let badge = Task { await entry.load() }
        for _ in 0..<1_000 {
            if await gate.started {
                break
            }
            await Task.yield()
        }
        #expect(await gate.started)
        badge.cancel()
        let view = Task { await entry.load() }
        await Task.yield()
        #expect(entry.pendingRecovery == saved)
        await gate.release()
        await view.value
        await badge.value
        #expect(entry.pendingRecovery == nil && entry.recoveryIssue == nil)
        #expect(entry.store.hasLoaded && entry.store.state.commitMessage == "shared unsent draft")
    }

    @Test("A changed Stash list is rejected instead of assigning a new object to old preview metadata")
    func changedStashSnapshot() async throws {
        actor IdentityRead {
            let refs: [String]
            var count = 0
            init(refs: [String]) {
                self.refs = refs
            }

            func next() -> [String: String] {
                count += 1
                return Dictionary(uniqueKeysWithValues: refs.map { ($0, String(repeating: count == 1 ? "a" : "b", count: 40)) })
            }
        }
        let mock = MockGitProvider(delay: .zero)
        let reader = try IdentityRead(refs: await mock.loadStashes().map(\.ref))
        let provider = WorkspaceGitProvider(base: mock, stashIdentities: { await reader.next() })
        await #expect(throws: WorkspaceRecoveryError.self) { try await provider.loadStashes() }
    }
}
