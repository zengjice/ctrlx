import CtrlxCommon
import CtrlxNetworking
import Darwin
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

struct HostFileBrowserTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-files-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func directoryPagingAndHiddenFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for n in 0..<240 { try Data().write(to: root.appendingPathComponent("file\(n).swift")) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".secret"))
        let host = HostFileBrowser()
        guard case let .listing(first) = try await host.request(.list(path: root.path, offset: 0, includeHidden: false)),
              let next = first.nextOffset,
              case let .listing(second) = try await host.request(.list(path: root.path, offset: next, includeHidden: false)) else {
            Issue.record("Missing pages"); return
        }
        #expect(first.entries.count == FileBrowserLimits.directoryPageSize)
        #expect(first.entries.first?.kind == .directory)
        #expect(first.entries.first?.name == "folder")
        #expect(first.revision == second.revision)
        #expect(second.nextOffset == nil)
        let all = first.entries + second.entries
        #expect(Set(all.map(\.path)).count == 241)
        #expect(!all.contains { $0.name == ".secret" })
        #expect(try JSONEncoder().encode(first).count < 150 * 1024)
        guard case let .listing(hidden) = try await host.request(.list(path: root.path, offset: 0, includeHidden: true)) else { return }
        #expect(hidden.entries.contains { $0.name == ".secret" })
    }

    @Test func chunkedReadsAndChangingFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("file.md")
        let contents = Data(repeating: 65, count: FileBrowserLimits.chunkBytes + 7)
        try contents.write(to: path)
        let host = HostFileBrowser()
        guard case let .info(info) = try await host.request(.info(path: path.path)),
              case let .chunk(first) = try await host.request(.read(path: path.path, offset: 0, revision: info.revision)),
              case let .chunk(second) = try await host.request(.read(path: path.path, offset: first.data.count, revision: info.revision)) else { return }
        #expect(info.kind == .markdown)
        #expect(first.data.count == FileBrowserLimits.chunkBytes)
        #expect(second.offset == first.data.count)
        #expect(first.data + second.data == contents)
        try Data("changed".utf8).write(to: path, options: .atomic)
        await #expect(throws: FileBrowserError.self) {
            try await host.request(.read(path: path.path, offset: first.data.count, revision: info.revision))
        }
    }

    @Test func rejectsSpecialAndOversizedFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 0, count: FileBrowserLimits.maximumTextBytes + 1).write(to: large)
        let host = HostFileBrowser()
        for path in [fifo, large, root] {
            guard case let .info(info) = try await host.request(.info(path: path.path)) else { return }
            await #expect(throws: FileBrowserError.self) {
                try await host.request(.read(path: path.path, offset: 0, revision: info.revision))
            }
        }
        await #expect(throws: FileBrowserError.self) {
            try await host.request(.list(path: root.path, offset: -1, includeHidden: false))
        }
        await #expect(throws: FileBrowserError.self) { try await host.request(.info(path: "relative")) }
    }

    @Test func textAndNameSearchDoNotFollowSymlinkLoops() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("子目录")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("first\nfind a needle here\nlast".utf8).write(to: child.appendingPathComponent("hello.swift"))
        try Data("needle".utf8).write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: child.appendingPathComponent("loop"), withDestinationURL: root)
        let host = HostFileBrowser()
        guard case let .search(text) = try await host.request(.search(path: root.path, query: "needle", mode: .content, includeHidden: false)),
              case let .search(name) = try await host.request(.search(path: root.path, query: "HELLO", mode: .name, includeHidden: false)) else { return }
        #expect(text.matches.count == 1)
        #expect(text.matches.first?.lineNumber == 2)
        #expect(!text.isTruncated)
        #expect(name.matches.first?.entry.name == "hello.swift")
        guard case let .listing(link) = try await host.request(.list(path: child.appendingPathComponent("loop").path, offset: 0, includeHidden: false)) else { return }
        #expect(link.entries.allSatisfy { $0.path.hasPrefix(child.appendingPathComponent("loop").path + "/") })
    }

    @Test func contentSearchReadsBeyondTheFirstChunk() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "a", count: FileBrowserLimits.chunkBytes + 1) + "\nneedle"
        try Data(text.utf8).write(to: root.appendingPathComponent("large.txt"))
        guard case let .search(result) = try await HostFileBrowser().request(.search(path: root.path, query: "needle", mode: .content, includeHidden: false)) else {
            Issue.record("Missing search result"); return
        }
        #expect(result.matches.count == 1)
        #expect(result.matches.first?.lineNumber == 2)
        #expect(!result.isTruncated)
    }
}

@MainActor
struct FileBrowserLayoutTests {
    @Test("Selecting a new terminal replaces Files/browser content without closing tabs or disturbing the right pane", arguments: [true, false])
    func newTerminalClearsAuxiliarySelection(fromFiles: Bool) {
        let tabs = SessionFileTabsState()
        let directory = FileBrowserTab(path: "/host/project")
        let browser = BrowserTab(url: URL(string: "https://example.com")!)
        tabs.directoryTabs[directory.id] = directory
        tabs.openFileTabs = [.init(id: directory.id, path: "Files", directoryPath: "", isDirectory: true)]
        tabs.openBrowserTabs = [browser]
        tabs.selectedFileTabId = fromFiles ? directory.id : nil
        tabs.selectedBrowserTabId = fromFiles ? nil : browser.id
        tabs.rightSide = [.window("@right")]
        tabs.selectedRight = .window("@right")

        #expect(tabs.selectLeftTerminalWindow("@new"))
        #expect(tabs.selectedFileTabId == nil)
        #expect(tabs.selectedBrowserTabId == nil)
        #expect(tabs.directoryTabs[directory.id] === directory)
        #expect(tabs.openFileTabs.count == 1)
        #expect(tabs.openBrowserTabs.map(\.id) == [browser.id])
        #expect(tabs.rightSide == [.window("@right")])
        #expect(tabs.selectedRight == .window("@right"))
    }

    @Test func rightSideTerminalDoesNotReplaceLeftFiles() {
        let tabs = SessionFileTabsState()
        let fileID = UUID()
        tabs.selectedFileTabId = fileID
        tabs.rightSide = [.window("@right")]
        tabs.selectedRight = .window("@right")
        #expect(!tabs.selectLeftTerminalWindow("@right"))
        #expect(tabs.selectedFileTabId == fileID)
        #expect(tabs.selectedRight == .window("@right"))
    }

    @Test func directorySelectionNeverLeavesALegacyExplorerBehind() {
        let tabs = SessionFileTabsState()
        let directory = FileBrowserTab(path: "/host/project")
        tabs.directoryTabs[directory.id] = directory
        tabs.openFileTabs = [.init(id: directory.id, path: "Files", directoryPath: "", isDirectory: true)]
        var legacyWindows: Set<String> = ["other-window"]

        tabs.selectLeftFileTab(directory.id, windowID: "window", legacyExplorerWindows: &legacyWindows)
        tabs.selectedFileTabId = nil // Return to the terminal, then reselect Files.
        legacyWindows.insert("window") // A prior editor selection must not leak into Files.
        for _ in 0..<2 {
            tabs.selectedBrowserTabId = UUID()
            tabs.selectLeftFileTab(directory.id, windowID: "window", legacyExplorerWindows: &legacyWindows)
            #expect(tabs.selectedFileTabId == directory.id)
            #expect(tabs.selectedBrowserTabId == nil)
            #expect(legacyWindows == ["other-window"])

            tabs.rightSide.insert(.file(directory.id))
            tabs.selectedRight = .file(directory.id)
            tabs.selectedFileTabId = nil
            #expect(!legacyWindows.contains("window"), "Moving Files right must reveal the terminal, not an unlisted explorer")
            tabs.rightSide.remove(.file(directory.id))
            tabs.selectedRight = nil
        }
    }

    @Test func editorSelectionStillKeepsItsLegacyTree() {
        let tabs = SessionFileTabsState()
        let editor = OpenFileTab(path: "/host/file.swift", directoryPath: "/host")
        tabs.openFileTabs = [editor]
        tabs.selectedBrowserTabId = UUID()
        var legacyWindows: Set<String> = []
        tabs.selectLeftFileTab(editor.id, windowID: "window", legacyExplorerWindows: &legacyWindows)
        #expect(legacyWindows == ["window"])
        #expect(tabs.selectedFileTabId == editor.id)
        #expect(tabs.selectedBrowserTabId == nil)
    }

    @Test func localSourceUsesTheRequestedPaneAndFreshCwd() async throws {
        let calls = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[LoginItemService.self] = .previewValue
            $0[ProcessRunner.self] = .init(run: { _, arguments, _, _ in
                calls.withValue { $0.append(arguments) }
                return .init(exitCode: 0, stdout: Data("/host/fresh-cwd\n".utf8), stderr: Data())
            })
            $0[SessionDirectoryClient.self].resolve = { path in
                if path == "/deleted" { throw FileBrowserError.message("Deleted directory") }
                return path == "~/" ? "/host/home" : path
            }
            $0[FileBrowserClient.self].request = { operation in
                guard case let .list(path?, _, _) = operation else { throw FileBrowserError.message("Missing directory") }
                return .listing(.init(directory: path, homeDirectory: "/host/home", entries: [], nextOffset: nil, revision: "1"))
            }
        } operation: {
            let tmux = TmuxService()
            let manager = MirrorWindowManager(settings: AppSettings(), tmuxService: tmux,
                paneStreamManager: PaneStreamManager(tmuxService: tmux, controlClientManager: TmuxControlClientManager()),
                editorSessionManager: EditorSessionManager())
            manager.setPaneStatesForPreview([
                .init(paneId: "%1", currentPath: "/wrong-active", isActive: true),
                .init(paneId: "%42", currentPath: "/stale", agentSession: .init(paneId: "%42", detectedProjectPath: "/host/agent")),
                .init(paneId: "%43", currentPath: "/stale", agentSession: .init(paneId: "%43", detectedProjectPath: "/deleted")),
            ])
            for (pane, expected) in [("%42", "/host/agent"), ("%43", "/host/fresh-cwd"), ("%44", "/host/fresh-cwd")] {
                let source = FileBrowserSource.local(paneID: pane, tmux: tmux, windows: manager)
                guard case let .listing(result) = try await source.request(.list(path: nil, offset: 0, includeHidden: false)) else { return }
                #expect(result.directory == expected)
                #expect(calls.value.last == ["display-message", "-p", "-t", pane, "#{pane_current_path}"])
            }
            let source = FileBrowserSource.local(paneID: "%42", tmux: tmux, windows: manager)
            let count = calls.value.count
            _ = try await source.request(.list(path: "/chosen", offset: 0, includeHidden: false))
            #expect(calls.value.count == count)
        }
    }

    @Test func directoryTabsSurvivePrivateViewerLayoutRoundTrip() throws {
        let tabs = SessionFileTabsState()
        let first = FileBrowserTab(path: "/host/project1", sourcePaneID: "%42")
        first.expanded = ["/host/project1/src"]
        first.selectedFile = "/host/project1/README.md"
        let second = FileBrowserTab(path: "/host/project2", sourcePaneID: "%43")
        for tab in [first, second] {
            tabs.directoryTabs[tab.id] = tab
            tabs.openFileTabs.append(.init(id: tab.id, path: "Files", directoryPath: "", isDirectory: true))
        }
        tabs.tabOrder = [.window("@1"), .file(first.id), .file(second.id)]
        tabs.rightSide = [.file(second.id)]
        tabs.selectedRight = .file(second.id)
        tabs.selectedFileTabId = first.id
        let saved = LayoutSnapshotMapper.viewerPrivateLayout(from: LayoutSnapshotMapper.snapshot(from: tabs, fileBrowser: nil, windowIndexForId: { _ in 0 }))
        let restored = SessionFileTabsState()
        let decoded = try JSONDecoder().decode(SavedFolderLayout.self, from: JSONEncoder().encode(saved))
        LayoutSnapshotMapper.apply(decoded, to: restored, fileBrowser: nil, windowIdForIndex: { _ in nil }, makeBrowserState: { BrowserTabState(initialURL: $0.url) })
        #expect(restored.openFileTabs.count == 2)
        #expect(restored.openFileTabs.allSatisfy { $0.isDirectory })
        #expect(restored.directoryTabs[first.id]?.path == "/host/project1")
        #expect(restored.directoryTabs[first.id]?.expanded == first.expanded)
        #expect(restored.directoryTabs[first.id]?.sourcePaneID == nil)
        #expect(restored.selectedFileTabId == first.id)
        #expect(restored.selectedRight == .file(second.id))
        #expect(!restored.tabOrder.contains(.window("@1")))
    }

    @Test func legacyExplorerBecomesAnOrdinaryClosableTab() {
        let tabs = SessionFileTabsState()
        tabs.tabOrder = [.window("@1"), .fileExplorer]
        tabs.rightSide = [.fileExplorer]
        tabs.selectedRight = .fileExplorer
        tabs.migrateLegacyExplorer(directory: "/host")
        tabs.migrateLegacyExplorer(directory: "/different")
        #expect(tabs.openFileTabs.count == 1)
        #expect(tabs.directoryTabs.values.first?.path == "/host")
        #expect(!tabs.tabOrder.contains(.fileExplorer))
        #expect(tabs.selectedRight == tabs.openFileTabs.first.map { .file($0.id) })
    }
}
