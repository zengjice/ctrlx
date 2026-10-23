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
        }
    }

    @Test("Non-Git links and previews stay inside the Agent project directory")
    @MainActor
    func nonGitWorkspace() async throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.appendingPathComponent("workspace-links-\(UUID())")
        let project = fixture.appendingPathComponent("work/nested")
        try files.createDirectory(at: project.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try files.createDirectory(at: project.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: fixture) }
        let name = "John's 报告 %27.md"
        let markdown = Data("# Report\n\n![Image](../images/cat.png)\n\n```mermaid\ngraph LR; A-->B\n```".utf8)
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWZkAAAAASUVORK5CYII="))
        try markdown.write(to: project.appendingPathComponent("docs/" + name))
        try image.write(to: project.appendingPathComponent("images/cat.png"))
        try Data("graph LR; A-->B".utf8).write(to: project.appendingPathComponent("diagram.mmd"))
        try Data("outside".utf8).write(to: fixture.appendingPathComponent("secret.txt"))
        try files.createSymbolicLink(atPath: project.appendingPathComponent("inside").path, withDestinationPath: "docs")
        try files.createSymbolicLink(atPath: project.appendingPathComponent("outside").path, withDestinationPath: fixture.path)
        let alias = fixture.appendingPathComponent("alias")
        try files.createSymbolicLink(atPath: alias.path, withDestinationPath: project.path)

        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            let host = HostFileBrowser()
            let root = project.resolvingSymlinksInPath().path
            let marker = try #require(RepositoryFileLink.marker(path: "docs/" + name))
            let relative = try #require(RepositoryFileLink.path(marker))
            for directory in [project.path, alias.path] {
                let entry = try await host.repositoryFile(path: relative, projectDirectory: directory)
                #expect(entry.path == root + "/docs/" + name && entry.kind == .markdown)
                let folder = try await host.repositoryFile(path: ".", projectDirectory: directory)
                #expect(folder.path == root && folder.kind == .directory)
                let inside = try await host.repositoryFile(path: "inside/" + name, projectDirectory: directory)
                #expect(inside == entry)
                for invalid in ["../secret.txt", "outside/secret.txt", fixture.appendingPathComponent("secret.txt").path, "secret.txt", "missing"] {
                    await #expect(throws: (any Error).self) {
                        try await host.repositoryFile(path: invalid, projectDirectory: directory)
                    }
                }
            }
            for directory in [project.appendingPathComponent("missing").path, fixture.appendingPathComponent("secret.txt").path] {
                await #expect(throws: (any Error).self) {
                    try await host.repositoryFile(path: ".", projectDirectory: directory)
                }
            }
            let context = RepositoryFileContext(pluginID: "codex", sessionID: "plain-folder", projectDirectory: project.path)
            let source = FileBrowserSource(id: "Host", paneID: "%1") { operation in
                if case let .repositoryInfo(path, received) = operation {
                    #expect(received == context)
                    return try await .info(host.repositoryFile(path: path, projectDirectory: received.projectDirectory))
                }
                return try await host.request(operation)
            }
            let folder = try await TerminalFileDestination.resolve(path: ".", context: context, source: source)
            #expect(folder.directory == root && folder.file == nil)
            let destination = try await TerminalFileDestination.resolve(path: relative, context: context, source: source)
            let preview = try TerminalArtifactPreview(link: .init(path: relative, paneID: "%1", hostID: "Host"), context: context, source: source, path: #require(destination.file))
            #expect(try await preview.load() == markdown)
            #expect(try await preview.loadDocumentImage("../images/cat.png") == image)
            await #expect(throws: (any Error).self) { try await preview.loadDocumentImage("../../secret.png") }
            let diagram = TerminalArtifactPreview(link: .init(path: "diagram.mmd", paneID: "%1", hostID: "Host"), context: context, source: source, path: root + "/diagram.mmd")
            #expect(try await diagram.load() == Data("graph LR; A-->B".utf8))
        }
    }

    @Test("Unreadable Git metadata must not select a same-named file in the launch directory", arguments: [".git", ".git/HEAD"])
    func unreadableGitMetadata(blockedPath: String) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("repository-permissions-\(UUID())")
        let nested = root.appendingPathComponent("src/nested")
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try await withDependencies {
            $0[ProcessRunner.self] = .liveValue
            $0.continuousClock = ContinuousClock()
        } operation: {
            _ = try await ProcessRunner.liveValue.runOrThrow(executable: "/usr/bin/git", arguments: ["-C", root.path, "init", "-q"])
            try Data("root".utf8).write(to: root.appendingPathComponent("report.txt"))
            try Data("wrong nested file".utf8).write(to: nested.appendingPathComponent("report.txt"))
            let host = HostFileBrowser()
            let expected = root.resolvingSymlinksInPath().appendingPathComponent("report.txt").path
            #expect(try await host.repositoryFile(path: "report.txt", projectDirectory: nested.path).path == expected)
            let blocked = root.appendingPathComponent(blockedPath)
            let permissions = try #require(files.attributesOfItem(atPath: blocked.path)[.posixPermissions] as? NSNumber)
            defer { try? files.setAttributes([.posixPermissions: permissions], ofItemAtPath: blocked.path) }
            try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            let result = try await ProcessRunner.liveValue.run("/usr/bin/git", ["-C", nested.path, "rev-parse", "--show-toplevel"], ["LC_ALL": "C"], 5)
            #expect(result.exitCode == 128)
            #expect(result.stderrString.hasPrefix("fatal: not a git repository (or any"))
            await #expect(throws: ProcessRunnerError.self) {
                try await host.repositoryFile(path: "report.txt", projectDirectory: nested.path)
            }
            try files.setAttributes([.posixPermissions: permissions], ofItemAtPath: blocked.path)
            #expect(try await host.repositoryFile(path: "report.txt", projectDirectory: nested.path).path == expected)
        }
    }

    @Test("Git errors cannot silently change the link root", arguments: [
        "fatal: detected dubious ownership in repository at '/project'",
        "fatal: not a git repository: /missing/worktree",
        "fatal: this operation must be run in a work tree",
    ])
    func gitFailure(stderr: String) async {
        await withDependencies {
            $0[ProcessRunner.self].run = { _, _, environment, _ in
                #expect(environment?["LC_ALL"] == "C")
                return .init(exitCode: 128, stdout: Data(), stderr: Data(stderr.utf8))
            }
        } operation: {
            await #expect(throws: ProcessRunnerError.self) {
                try await HostFileBrowser().repositoryFile(path: ".", projectDirectory: FileManager.default.temporaryDirectory.path)
            }
        }
    }

    @Test("Git timeout does not fall back to a directory link")
    func gitTimeout() async {
        await withDependencies {
            $0[ProcessRunner.self].run = { _, _, _, _ in throw ProcessRunnerError.timeout }
        } operation: {
            await #expect(throws: ProcessRunnerError.self) {
                try await HostFileBrowser().repositoryFile(path: ".", projectDirectory: FileManager.default.temporaryDirectory.path)
            }
        }
    }

    @Test("A changed source Agent rejects resolution before and after I/O", arguments: [false, true])
    @MainActor
    func sourceContextChanges(duringIO: Bool) async throws {
        let calls = LockIsolated(0)
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (resume, signalResume) = AsyncStream<Void>.makeStream()
        defer { signalStarted.finish()
            signalResume.finish()
        }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[FileBrowserClient.self].repositoryFile = { path, directory in
                calls.withValue { $0 += 1 }
                signalStarted.yield()
                for await _ in resume {
                    break
                }
                return .init(path: directory + "/" + path, name: path, kind: .text, size: 0, revision: "1")
            }
        } operation: {
            let tmux = TmuxService()
            let manager = MirrorWindowManager(
                settings: AppSettings(),
                tmuxService: tmux,
                paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                editorSessionManager: EditorSessionManager()
            )
            var pane = PaneState(
                paneId: "%42",
                currentPath: "/wrong-shell-cwd",
                agentSession: .init(paneId: "%42", pluginID: "codex", detectedProjectPath: "/project")
            )
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
                for await _ in started {
                    break
                }
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
        #expect(RepositoryFileContext(pane: .init(
            paneId: "%1",
            currentPath: "/shell",
            agentSession: .init(paneId: "%1")
        )) == nil)
    }
}
