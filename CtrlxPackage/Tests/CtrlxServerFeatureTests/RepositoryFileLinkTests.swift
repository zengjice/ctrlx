import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct RepositoryFileLinkTests {
    @Test("Repository files use the linked worktree root, including nested launch directories")
    func linkedWorktreeAndContainment() async throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent("repository-links-\(UUID())")
        let primary = fixture.appendingPathComponent("main")
        let linked = fixture.appendingPathComponent("linked")
        try files.createDirectory(at: primary, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: fixture) }
        func git(_ arguments: [String]) async throws {
            _ = try await ProcessRunner.liveValue.runOrThrow(executable: "/usr/bin/git", arguments: [
                "-C", primary.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
            ] + arguments)
        }
        try await git(["init", "-q"])
        try await git(["commit", "--allow-empty", "-m", "fixture"])
        try await git(["worktree", "add", "--detach", linked.path, "HEAD"])
        let nested = linked.appendingPathComponent("src/nested")
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        let name = "John's 完整片 %27.mp4"
        try Data("linked".utf8).write(to: linked.appendingPathComponent(name))
        try Data("primary".utf8).write(to: primary.appendingPathComponent(name))
        try files.createSymbolicLink(atPath: linked.appendingPathComponent("inside").path, withDestinationPath: name)
        try files.createSymbolicLink(atPath: linked.appendingPathComponent("outside").path, withDestinationPath: primary.path)
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let host = HostFileBrowser()
            let root = linked.resolvingSymlinksInPath().path
            for path in [name, "inside"] {
                let entry = try await host.repositoryFile(path: path, projectDirectory: nested.path)
                #expect(entry.path == root + "/" + name)
                #expect(entry.size == 6)
            }
            let directory = try await host.repositoryFile(path: ".", projectDirectory: nested.path)
            #expect(directory.path == root && directory.kind == .directory)
            for invalid in ["../main/" + name, "/tmp/file", "outside/" + name, "missing"] {
                await #expect(throws: (any Error).self) {
                    try await host.repositoryFile(path: invalid, projectDirectory: nested.path)
                }
            }
            await #expect(throws: (any Error).self) {
                try await host.repositoryFile(path: name, projectDirectory: fixture.path)
            }
        }
    }

    @Test("A changed source Agent rejects resolution before and after I/O", arguments: [false, true])
    @MainActor
    func sourceContextChanges(duringIO: Bool) async throws {
        let calls = LockIsolated(0)
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (resume, signalResume) = AsyncStream<Void>.makeStream()
        defer { signalStarted.finish(); signalResume.finish() }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[FileBrowserClient.self].repositoryFile = { path, directory in
                calls.withValue { $0 += 1 }
                signalStarted.yield()
                for await _ in resume { break }
                return .init(path: directory + "/" + path, name: path, kind: .text, size: 0, revision: "1")
            }
        } operation: {
            let tmux = TmuxService()
            let manager = MirrorWindowManager(settings: AppSettings(), tmuxService: tmux,
                paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                editorSessionManager: EditorSessionManager())
            var pane = PaneState(paneId: "%42", currentPath: "/wrong-shell-cwd",
                                 agentSession: .init(paneId: "%42", pluginID: "codex", detectedProjectPath: "/project"))
            pane.claudeSessionID = "first"
            let context = try #require(RepositoryFileContext(pane: pane))
            manager.setPaneStatesForPreview([pane])
            let source = FileBrowserSource.local(paneID: pane.paneId, tmux: tmux, windows: manager)
            if !duringIO {
                pane.claudeSessionID = "second"
                manager.setPaneStatesForPreview([pane])
            }
            let task = Task { try await source.request(.repositoryInfo(path: "report.pdf", context: context)) }
            if duringIO {
                for await _ in started { break }
                pane.claudeSessionID = "second"
                manager.setPaneStatesForPreview([pane])
                signalResume.yield()
            }
            await #expect(throws: (any Error).self) { try await task.value }
            #expect(calls.value == (duringIO ? 1 : 0))
        }
    }

    @Test("No Agent project means no cwd fallback")
    func unavailableContext() {
        #expect(RepositoryFileContext(pane: .init(paneId: "%1", currentPath: "/shell")) == nil)
        #expect(RepositoryFileContext(pane: .init(paneId: "%1", currentPath: "/shell",
                                                agentSession: .init(paneId: "%1"))) == nil)
    }
}
