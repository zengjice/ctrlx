import CtrlxCommon
import CtrlxNetworking
import AVFoundation
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

    @Test("System-hidden files and directories match search visibility", arguments: [false, true])
    func systemHiddenEntries(includeHidden: Bool) async throws {
        let files = FileManager.default
        let root = try fixture()
        defer { try? files.removeItem(at: root) }
        for name in ["visible.txt", "flag-hidden.txt", ".dot-hidden.txt"] {
            try Data("needle".utf8).write(to: root.appendingPathComponent(name))
        }
        for name in ["visible-folder", "flag-hidden-folder", ".dot-hidden-folder"] {
            let folder = root.appendingPathComponent(name)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("needle".utf8).write(to: folder.appendingPathComponent("child.txt"))
        }
        for name in ["flag-hidden.txt", "flag-hidden-folder"] {
            try #require(chflags(root.appendingPathComponent(name).path, UInt32(UF_HIDDEN)) == 0)
        }
        let host = HostFileBrowser()
        guard case let .listing(listing) = try await host.request(.list(path: root.path, offset: 0, includeHidden: includeHidden)),
              case let .search(search) = try await host.request(.search(path: root.path, query: "hidden", mode: .name, includeHidden: includeHidden)),
              case let .search(content) = try await host.request(.search(path: root.path, query: "needle", mode: .content, includeHidden: includeHidden)) else {
            Issue.record("Missing listing or search response"); return
        }
        let visible: Set<String> = ["visible.txt", "visible-folder"]
        let hidden: Set<String> = ["flag-hidden.txt", "flag-hidden-folder", ".dot-hidden.txt", ".dot-hidden-folder"]
        #expect(Set(listing.entries.map(\.name)) == (includeHidden ? visible.union(hidden) : visible))
        #expect(Set(search.matches.map(\.entry.name)) == (includeHidden ? hidden : []))
        #expect(content.matches.count == (includeHidden ? 6 : 2))
        #expect(!content.isTruncated)
        #expect(listing.entries.filter { $0.kind == .directory }.allSatisfy { $0.revision.isEmpty })
    }

    @Test("System-hidden entries are excluded before pagination")
    func systemHiddenEntriesDoNotConsumePageSlots() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Long UTF-8 names make the attributes exceed one bulk-read buffer.
        let prefix = "资料 ' $(x) " + String(repeating: "长", count: 40)
        for n in 0..<205 {
            try Data().write(to: root.appendingPathComponent("\(prefix)visible\(n).txt"))
            let hidden = root.appendingPathComponent("\(prefix)hidden\(n).txt")
            try Data().write(to: hidden)
            try #require(chflags(hidden.path, UInt32(UF_HIDDEN)) == 0)
        }
        let host = HostFileBrowser()
        guard case let .listing(first) = try await host.request(.list(path: root.path, offset: 0, includeHidden: false)),
              let next = first.nextOffset,
              case let .listing(second) = try await host.request(.list(path: root.path, offset: next, includeHidden: false)) else {
            Issue.record("Missing pages"); return
        }
        #expect(first.entries.count == FileBrowserLimits.directoryPageSize)
        #expect(second.entries.count == 5)
        #expect(second.nextOffset == nil)
        #expect((first.entries + second.entries).map(\.name) == (0..<205).map { "\(prefix)visible\($0).txt" })
    }

    @Test("Listing a known directory or mount point never reads child metadata")
    func directoryRowsDeferMetadataUntilNavigation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // A nonexistent path makes any accidental stat fail, without a real NFS dependency.
        let path = root.appendingPathComponent("offline-mount").path
        let host = HostFileBrowser()
        let item = try await host.listedEntry(path: path, type: VDIR.rawValue)
        #expect(item.path == path)
        #expect(item.name == "offline-mount")
        #expect(item.kind == .directory)
        #expect(item.size == 0)
        #expect(item.revision.isEmpty)
        #expect(!item.isSymbolicLink)
        await #expect(throws: NSError.self) { try await host.request(.info(path: path)) }
        await #expect(throws: NSError.self) { try await host.request(.list(path: path, offset: 0, includeHidden: false)) }
        for type in [VNON, VLNK, VREG] {
            await #expect(throws: NSError.self) { try await host.listedEntry(path: path, type: type.rawValue) }
        }
    }

    @Test("Unknown types and symbolic links still validate metadata, preserving literal paths and immediate children")
    func directoryEntryFallbackAndLinks() async throws {
        let files = FileManager.default
        let root = try fixture()
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent("新目录 ' $(x)")
        try files.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("hello.md")
        try Data("hello".utf8).write(to: file)
        try files.createDirectory(at: root.appendingPathComponent(".hidden-folder"), withIntermediateDirectories: true)
        try files.createSymbolicLink(atPath: root.appendingPathComponent("directory-link").path, withDestinationPath: folder.lastPathComponent)
        try files.createSymbolicLink(atPath: root.appendingPathComponent("file-link.md").path, withDestinationPath: file.lastPathComponent)
        try files.createSymbolicLink(atPath: root.appendingPathComponent("broken-link").path, withDestinationPath: "missing")

        let host = HostFileBrowser()
        let unknown = try await host.listedEntry(path: folder.path, type: VNON.rawValue)
        #expect(unknown.kind == .directory)
        #expect(!unknown.revision.isEmpty)
        guard case let .listing(listing) = try await host.request(.list(path: root.path, offset: 0, includeHidden: false)) else {
            Issue.record("Missing listing"); return
        }
        #expect(Set(listing.entries.map(\.name)) == [folder.lastPathComponent, "hello.md", "directory-link", "file-link.md"])
        #expect(listing.entries.allSatisfy { $0.path == root.appendingPathComponent($0.name).path })
        #expect(listing.entries.prefix(2).allSatisfy { $0.kind == .directory })
        let direct = try #require(listing.entries.first { $0.path == folder.path })
        #expect(direct.revision.isEmpty)
        let directoryLink = try #require(listing.entries.first { $0.name == "directory-link" })
        #expect(directoryLink.kind == .directory)
        #expect(directoryLink.isSymbolicLink)
        #expect(!directoryLink.revision.isEmpty)
        let fileLink = try #require(listing.entries.first { $0.name == "file-link.md" })
        #expect(fileLink.kind == .markdown)
        #expect(fileLink.isSymbolicLink)
        #expect(fileLink.size == 5)
        #expect(!fileLink.revision.isEmpty)
        guard case let .info(info) = try await host.request(.info(path: folder.path)),
              case let .listing(children) = try await host.request(.list(path: folder.path, offset: 0, includeHidden: false)),
              case let .listing(hidden) = try await host.request(.list(path: root.path, offset: 0, includeHidden: true)) else {
            Issue.record("Missing directory metadata or listing"); return
        }
        #expect(!info.revision.isEmpty)
        #expect(children.entries.map(\.name) == ["nested"])
        #expect(hidden.entries.contains { $0.name == ".hidden-folder" })
    }

    @Test("Directory rows preserve sorting and pagination across multiple pages")
    func directoryPaging() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<205 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder\(index)"), withIntermediateDirectories: true)
        }
        try Data("hello".utf8).write(to: root.appendingPathComponent("file.txt"))
        let host = HostFileBrowser()
        guard case let .listing(first) = try await host.request(.list(path: root.path, offset: 0, includeHidden: false)),
              let next = first.nextOffset,
              case let .listing(second) = try await host.request(.list(path: root.path, offset: next, includeHidden: false)) else {
            Issue.record("Missing pages"); return
        }
        let all = first.entries + second.entries
        #expect(first.entries.count == FileBrowserLimits.directoryPageSize)
        #expect(second.entries.count == 6)
        #expect(second.nextOffset == nil)
        #expect(first.revision == second.revision)
        #expect(Set(all.map(\.path)).count == 206)
        #expect(all.dropLast().map(\.name) == (0..<205).map { "folder\($0)" })
        #expect(all.dropLast().allSatisfy { $0.kind == .directory && $0.revision.isEmpty })
        #expect(all.last?.name == "file.txt")
        #expect(all.last?.size == 5)
        #expect(all.last?.revision.isEmpty == false)
    }

    @Test("Explicit read-only Files Home probe", .enabled(if: ProcessInfo.processInfo.environment["CTRLX_VERIFY_FILE_BROWSER_HOME"] == "1"))
    func liveHomeProbe() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        guard case let .listing(result) = try await HostFileBrowser().request(.list(path: "~/", offset: 0, includeHidden: false)) else {
            Issue.record("Missing Home listing"); return
        }
        #expect(result.directory == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(!result.entries.isEmpty)
        #expect(result.entries.allSatisfy { !$0.name.hasPrefix(".") })
        print("Files Home probe: \(result.entries.count) entries in \(start.duration(to: clock.now))")
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

    @Test func localVideoAndExplicitDownloadDoNotRelaxInlinePreviewLimits() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("movie.mp4")
        try Data([0, 1, 2]).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(FileBrowserLimits.maximumPreviewBytes + 1))
        try handle.close()
        let host = HostFileBrowser()
        guard case let .info(info) = try await host.request(.info(path: url.path)) else { return }
        #expect(info.kind == .unsupported)
        #expect(try await host.localFileURL(info) == url)
        await #expect(throws: FileBrowserError.self) {
            try await host.request(.read(path: info.path, offset: 0, revision: info.revision))
        }
        guard case let .chunk(chunk) = try await host.request(.download(path: info.path, offset: 0, revision: info.revision)) else { return }
        #expect(chunk.data.count == FileBrowserLimits.chunkBytes)
        #expect(chunk.data.prefix(3) == Data([0, 1, 2]))
        try Data("replacement".utf8).write(to: url, options: .atomic)
        await #expect(throws: FileBrowserError.self) { try await host.localFileURL(info) }
        await #expect(throws: FileBrowserError.self) {
            try await host.request(.download(path: info.path, offset: 0, revision: info.revision))
        }
    }

    @MainActor @Test func nativePreviewLoadsTheRealMP4Fixture() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = package.appendingPathComponent("Sources/CtrlxE2ELib/Scenarios/SampleFiles/test_video.mp4")
        let host = HostFileBrowser()
        let source = FileBrowserSource(id: "local", paneID: nil, localFileURL: { try await host.localFileURL($0) }) { try await host.request($0) }
        let tab = FileBrowserTab()
        tab.selectedFile = url.path
        await tab.loadPreview(source: source)
        let nativeURL = try #require(tab.previewURL)
        #expect(nativeURL == url)
        #expect(tab.previewData == nil)
        #expect(tab.previewError == nil)
        #expect(try await AVURLAsset(url: nativeURL).load(.isPlayable))
        tab.releasePreview()
        #expect(tab.previewURL == nil)
    }

    @Test func downloadsRejectSpecialFilesAndOversizeEvenAtZeroOffset() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("pipe.mp4")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let large = root.appendingPathComponent("large.mp4")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FileBrowserLimits.maximumDownloadBytes + 1))
        try handle.close()
        let host = HostFileBrowser()
        for url in [fifo, large, root] {
            guard case let .info(info) = try await host.request(.info(path: url.path)) else { return }
            await #expect(throws: FileBrowserError.self) {
                try await host.request(.download(path: info.path, offset: 0, revision: info.revision))
            }
        }
        guard case let .info(info) = try await host.request(.info(path: fifo.path)) else { return }
        await #expect(throws: FileBrowserError.self) { try await host.localFileURL(info) }
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
