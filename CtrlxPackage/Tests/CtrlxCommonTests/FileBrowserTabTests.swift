import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct FileBrowserTabTests {
    @Test func localMoviePreviewUsesNativeURLWithoutReadingOrApplyingTransferLimit() async {
        let tab = FileBrowserTab(path: "/host")
        let info = FileBrowserEntry(path: "/host/movie.mp4", name: "movie.mp4", kind: .unsupported,
                                    size: FileBrowserLimits.maximumDownloadBytes + 1, revision: "1")
        tab.selectedFile = info.path
        var reads = 0
        let source = FileBrowserSource(id: "local", paneID: nil, localFileURL: { item in
            #expect(item == info)
            return URL(fileURLWithPath: item.path)
        }) { operation in
            if case .info = operation { return .info(info) }
            reads += 1
            throw FileBrowserError.message("A local movie must not be transferred")
        }
        await tab.loadPreview(source: source)
        #expect(tab.previewURL?.path == info.path)
        #expect(tab.previewData == nil)
        #expect(tab.previewError == nil)
        #expect(reads == 0)
        tab.releasePreview()
        #expect(tab.previewURL == nil)
    }

    @Test func remoteMovieSelectionDoesNotReadOrConstructALocalURL() async {
        let tab = FileBrowserTab(path: "/host")
        let info = FileBrowserEntry(path: "/host/movie.mp4", name: "movie.mp4", kind: .unsupported, size: 3, revision: "1")
        tab.selectedFile = info.path
        var reads = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation { return .info(info) }
            reads += 1
            throw FileBrowserError.message("Selection must not download")
        }
        await tab.loadPreview(source: source)
        #expect(tab.previewURL == nil)
        #expect(tab.previewData == nil)
        #expect(tab.previewError != nil)
        #expect(reads == 0)
    }

    private func source(_ path: String) -> FileBrowserSource {
        .init(id: path, paneID: nil) { _ in .listing(.init(directory: path, homeDirectory: "/Host", entries: [], nextOffset: nil, revision: "1")) }
    }

    @Test func sourceDirectoryFreezesUntilExplicitFollow() async {
        let tab = FileBrowserTab(sourcePaneID: "%42")
        var paths: [String?] = []
        let source = FileBrowserSource(id: "Host", paneID: "%42") { request in
            guard case let .list(path, _, _) = request else { throw FileBrowserError.message("Unexpected request") }
            paths.append(path)
            return .listing(.init(directory: path ?? "/Host/pane42", homeDirectory: "/Host", entries: [], nextOffset: nil, revision: "1"))
        }
        let initialLoadKey = tab.loadKey(source: source)
        await tab.load(source: source)
        #expect(tab.loadKey(source: source) == initialLoadKey)
        await tab.load(source: source)
        #expect(paths.count == 2)
        #expect(paths[0] == nil)
        #expect(paths[1] == "/Host/pane42")
        tab.navigate(nil)
        await tab.load(source: source)
        #expect(paths[2] == nil)
    }

    @Test func lateReplyCannotOverwriteNewHostOrPath() async {
        let tab = FileBrowserTab()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (started, notify) = AsyncStream<Void>.makeStream()
        let old = FileBrowserSource(id: "office", paneID: "%1") { _ in
            notify.yield()
            for await _ in gate { break }
            return .listing(.init(directory: "/office", homeDirectory: "/office", entries: [], nextOffset: nil, revision: "old"))
        }
        let task = Task { await tab.load(source: old) }
        for await _ in started { break }
        tab.navigate("/home")
        await tab.load(source: source("/home"))
        release.yield(); release.finish(); notify.finish()
        await task.value
        #expect(tab.path == "/home")
        #expect(tab.listing?.revision == "1")
        #expect(tab.error == nil)
    }

    @Test func independentTabsAndUnavailableSource() async {
        let first = FileBrowserTab(sourcePaneID: "%1"), second = FileBrowserTab(sourcePaneID: "%2")
        await first.load(source: source("/one"))
        await second.load(source: source("/two"))
        first.navigate("/other")
        #expect(second.path == "/two")
        await first.load(source: .remote(hostID: "offline", paneID: "%1", connection: nil))
        #expect(first.error?.contains("offline") == true)
        #expect(first.listing == nil)
    }

    @Test func invalidAndChangedChunksAreNotDisplayed() async {
        let tab = FileBrowserTab(path: "/host")
        tab.selectedFile = "/host/file"
        let info = FileBrowserEntry(path: "/host/file", name: "file", kind: .text, size: 3, revision: "1")
        let source = FileBrowserSource(id: "host", paneID: nil) { request in
            switch request {
            case .info: return .info(info)
            case .read: return .chunk(.init(path: info.path, revision: "changed", offset: 0, data: Data("abc".utf8)))
            default: throw FileBrowserError.message("Unexpected operation")
            }
        }
        await tab.loadPreview(source: source)
        #expect(tab.previewData == nil)
        #expect(tab.previewError != nil)
        #expect(!tab.isPreviewLoading)
    }

    @Test func binaryTextIsRejectedAndEmptyTextIsSupported() async {
        for data in [Data([0]), Data()] {
            let tab = FileBrowserTab(path: "/host")
            tab.selectedFile = "/host/file"
            let info = FileBrowserEntry(path: "/host/file", name: "file", kind: .text, size: data.count, revision: "1")
            let source = FileBrowserSource(id: "host", paneID: nil) { request in
                if case .info = request { return .info(info) }
                return .chunk(.init(path: info.path, revision: "1", offset: 0, data: data))
            }
            await tab.loadPreview(source: source)
            #expect(data.isEmpty ? tab.previewData == Data() : tab.previewData == nil)
            #expect(data.isEmpty ? tab.previewError == nil : tab.previewError != nil)
        }
    }

    @Test func changedDirectoryPagesCannotMixRevisions() async {
        let tab = FileBrowserTab(path: "/host")
        let entry = FileBrowserEntry(path: "/host/a", name: "a", kind: .text, size: 1, revision: "1")
        let source = FileBrowserSource(id: "host", paneID: nil) { operation in
            guard case let .list(_, offset, _) = operation else { throw FileBrowserError.message("Unexpected request") }
            return .listing(.init(directory: "/host", homeDirectory: "/host", entries: [entry],
                                  nextOffset: offset == 0 ? 1 : nil, revision: offset == 0 ? "old" : "new"))
        }
        await tab.load(source: source)
        await tab.loadDirectory("/host", more: true, source: source)
        #expect(tab.listing?.entries == [entry])
        #expect(tab.listing?.revision == "old")
        #expect(tab.error?.contains("Directory changed") == true)
    }

    @Test func leavingTabDiscardsLatePreview() async {
        let tab = FileBrowserTab(path: "/host")
        tab.selectedFile = "/host/a"
        let entry = FileBrowserEntry(path: "/host/a", name: "a", kind: .text, size: 1, revision: "1")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let (started, notify) = AsyncStream<Void>.makeStream()
        let source = FileBrowserSource(id: "host", paneID: nil) { operation in
            if case .info = operation { return .info(entry) }
            notify.yield()
            for await _ in gate { break }
            return .chunk(.init(path: entry.path, revision: "1", offset: 0, data: Data("a".utf8)))
        }
        let task = Task { await tab.loadPreview(source: source) }
        for await _ in started { break }
        tab.releasePreview()
        release.yield(); release.finish(); notify.finish()
        await task.value
        #expect(tab.previewData == nil)
        #expect(!tab.isPreviewLoading)
    }

    @Test(arguments: [true, false], [true, false])
    func searchEditsDismissOnlySingleColumnPreviews(singleColumn: Bool, changesMode: Bool) async throws {
        let tab = FileBrowserTab(path: "/host")
        tab.query = "old"
        tab.selectedFile = "/host/file"
        let entry = FileBrowserEntry(path: "/host/file", name: "file", kind: .text, size: 1, revision: "1")
        let source = FileBrowserSource(id: "host", paneID: nil) { operation in
            if case .info = operation { return .info(entry) }
            return .chunk(.init(path: entry.path, revision: "1", offset: 0, data: Data("a".utf8)))
        }
        await tab.loadPreview(source: source)
        #expect(tab.previewData != nil)
        tab.updateSearch(query: changesMode ? "old" : "new", mode: changesMode ? .content : .name,
                         dismissPreview: singleColumn)
        #expect(tab.selectedFile == (singleColumn ? nil : entry.path))
        #expect((tab.previewData == nil) == singleColumn)

        if singleColumn {
            let search = FileBrowserSource(id: "host", paneID: nil) { _ in .search(.init(matches: [], isTruncated: false)) }
            await tab.load(source: search)
            #expect(tab.searchResults?.matches.isEmpty == true)
            #expect(tab.selectedFile == nil)
            let failed = FileBrowserSource(id: "host", paneID: nil) { _ in throw FileBrowserError.message("Search failed") }
            await tab.load(source: failed)
            #expect(tab.error == "Search failed")
            #expect(tab.selectedFile == nil, "Search errors must be visible in the single-column directory page")
        }
    }

    @Test func unchangedSearchDoesNotDismissAChosenResult() {
        let tab = FileBrowserTab(path: "/host")
        tab.query = "needle"
        tab.selectedFile = "/host/result"
        tab.updateSearch(query: "needle", mode: .name, dismissPreview: true)
        #expect(tab.selectedFile == "/host/result")
        tab.updateSearch(query: "", mode: .name, dismissPreview: true)
        #expect(tab.selectedFile == nil)
    }
}
