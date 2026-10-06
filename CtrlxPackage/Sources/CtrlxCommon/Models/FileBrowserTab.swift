import CtrlxNetworking
import Foundation
import Observation
import UniformTypeIdentifiers

/// Client-private navigation state. No file contents or paths are broadcast as session state.
@MainActor @Observable
public final class FileBrowserTab: Identifiable {
    public struct Snapshot: Codable, Sendable, Hashable {
        public let id: UUID
        public let path: String
        public let includeHidden: Bool
        public let expanded: [String]
        public let selectedFile: String?
    }
    public let id: UUID
    public let sourcePaneID: String?
    public private(set) var path: String?
    private var requestedPath: String?
    public var pathInput: String
    public var includeHidden = false
    public var query = ""
    public var searchMode = FileBrowserSearchMode.name
    public var expanded: Set<String> = []
    public var selectedFile: String?
    public var refresh = 0
    public var searchFocusRequest = 0
    public private(set) var homeDirectory = "~/"
    public private(set) var listings: [String: FileBrowserListing] = [:]
    public private(set) var searchResults: FileBrowserSearchResults?
    public private(set) var preview: FileBrowserEntry?
    public private(set) var previewData: Data?
    public private(set) var previewURL: URL?
    public private(set) var error: String?
    public private(set) var previewError: String?
    public private(set) var isLoading = false
    public private(set) var isPreviewLoading = false
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var previewID = UUID()

    public init(id: UUID = UUID(), path: String? = nil, sourcePaneID: String? = nil) {
        self.id = id
        self.path = path
        self.requestedPath = path
        self.pathInput = path ?? ""
        self.sourcePaneID = sourcePaneID
    }

    public var title: String { "Files · \(path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? "/" : $0 } ?? "…")" }
    public var listing: FileBrowserListing? { path.flatMap { listings[$0] } }

    public var snapshot: Snapshot? {
        path.map { .init(id: id, path: $0, includeHidden: includeHidden, expanded: expanded.sorted(), selectedFile: selectedFile) }
    }

    public convenience init(snapshot: Snapshot) {
        // Pane IDs are process-lifetime handles, never persisted/rebound after restart.
        self.init(id: snapshot.id, path: snapshot.path)
        includeHidden = snapshot.includeHidden
        expanded = Set(snapshot.expanded)
        selectedFile = snapshot.selectedFile
    }

    public func releasePreview() {
        previewID = UUID()
        previewData = nil
        previewURL = nil
        isPreviewLoading = false
    }

    public func updateSearch(query: String, mode: FileBrowserSearchMode, dismissPreview: Bool) {
        guard self.query != query || searchMode != mode else { return }
        self.query = query
        searchMode = mode
        if dismissPreview {
            selectedFile = nil
            releasePreview()
        }
    }

    public struct LoadKey: Equatable {
        let path: String?
        let query: String
        let mode: FileBrowserSearchMode
        let hidden: Bool
        let refresh: Int
        let sourceID: String
        let unavailable: String?
    }

    public func loadKey(source: FileBrowserSource) -> LoadKey {
        .init(path: requestedPath, query: query, mode: searchMode, hidden: includeHidden,
              refresh: refresh, sourceID: source.id, unavailable: source.unavailableReason)
    }

    public func navigate(_ path: String?) {
        loadID = UUID()
        previewID = UUID()
        self.path = path
        requestedPath = path
        pathInput = path ?? ""
        query = ""
        selectedFile = nil
        listings = [:]
        expanded = []
        refresh += 1
    }

    public func load(source: FileBrowserSource) async {
        let token = UUID()
        loadID = token
        error = nil
        isLoading = true
        searchResults = nil
        // Reset pages, not expansion, so a refresh never combines different directory revisions.
        listings = [:]
        defer { if loadID == token { isLoading = false } }
        do {
            if let reason = source.unavailableReason { throw FileBrowserError.message(reason) }
            if !query.isEmpty, let path {
                try await Task.sleep(for: .milliseconds(250))
                let response = try await source.request(.search(path: path, query: query, mode: searchMode, includeHidden: includeHidden))
                try Task.checkCancellation()
                guard loadID == token, case let .search(result) = response else { return }
                searchResults = result
            } else {
                let response = try await source.request(.list(path: path, offset: 0, includeHidden: includeHidden))
                try Task.checkCancellation()
                guard loadID == token, case let .listing(result) = response else { return }
                path = result.directory
                pathInput = result.directory
                homeDirectory = result.homeDirectory
                listings[result.directory] = result
            }
        } catch is CancellationError { }
        catch { if loadID == token { self.error = error.localizedDescription } }
    }

    public func loadDirectory(_ directory: String, more: Bool, source: FileBrowserSource) async {
        let token = loadID
        let previous = listings[directory]
        let offset = more ? previous?.nextOffset : 0
        guard let offset else { return }
        do {
            let response = try await source.request(.list(path: directory, offset: offset, includeHidden: includeHidden))
            try Task.checkCancellation()
            guard token == loadID, case let .listing(result) = response else { return }
            if more, let previous {
                guard previous.revision == result.revision else { throw FileBrowserError.message("Directory changed. Refresh to load its new contents.") }
                // Ignore duplicate page requests rather than appending a page twice.
                guard listings[directory]?.nextOffset == offset else { return }
                listings[directory] = .init(directory: result.directory, homeDirectory: result.homeDirectory,
                                            entries: previous.entries + result.entries, nextOffset: result.nextOffset, revision: result.revision)
            } else { listings[directory] = result }
        } catch is CancellationError { }
        catch { if token == loadID { self.error = error.localizedDescription } }
    }

    public func loadPreview(source: FileBrowserSource) async {
        let token = UUID()
        previewID = token
        preview = nil
        previewData = nil
        previewURL = nil
        previewError = nil
        isPreviewLoading = false
        guard let selectedFile else { return }
        isPreviewLoading = true
        defer { if token == previewID { isPreviewLoading = false } }
        do {
            guard case let .info(info) = try await source.request(.info(path: selectedFile)) else {
                throw FileBrowserError.message("Missing file information.")
            }
            try Task.checkCancellation()
            guard token == previewID else { return }
            preview = info
            if let localFileURL = source.localFileURL, Self.isMedia(path: info.path) {
                let url = try await localFileURL(info)
                try Task.checkCancellation()
                guard token == previewID else { return }
                previewURL = url
                return
            }
            let limit = info.kind == .text || info.kind == .markdown ? FileBrowserLimits.maximumTextBytes : FileBrowserLimits.maximumPreviewBytes
            guard info.kind != .unsupported, info.kind != .directory, info.size >= 0, info.size <= limit else {
                throw FileBrowserError.message("This format or size cannot be previewed here. Open it in another app.")
            }
            var data = Data()
            while data.count < info.size {
                try Task.checkCancellation()
                guard case let .chunk(chunk) = try await source.request(.read(path: info.path, offset: data.count, revision: info.revision)),
                      chunk.path == info.path, chunk.revision == info.revision, chunk.offset == data.count,
                      !chunk.data.isEmpty, chunk.data.count <= FileBrowserLimits.chunkBytes, data.count + chunk.data.count <= info.size else {
                    throw FileBrowserError.message("File changed or the Host returned an invalid file chunk. Refresh its preview.")
                }
                data.append(chunk.data)
            }
            // Revalidate even the last chunk/empty file; do not display mixed revisions.
            guard case let .info(current) = try await source.request(.info(path: info.path)), current.revision == info.revision else {
                throw FileBrowserError.message("File changed. Refresh its preview.")
            }
            try Task.checkCancellation()
            guard token == previewID else { return }
            if info.kind == .text || info.kind == .markdown {
                guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                    throw FileBrowserError.message("This is not a UTF-8 text file.")
                }
            }
            previewData = data
        } catch is CancellationError { }
        catch { if token == previewID { previewError = error.localizedDescription } }
    }

    static func isMedia(path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}
