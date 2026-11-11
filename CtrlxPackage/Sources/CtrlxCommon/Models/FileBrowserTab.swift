import CtrlxNetworking
import Foundation
import Observation
import UniformTypeIdentifiers

/// Client-private navigation/preview state; only the Host's initial route is shared.
@MainActor @Observable
final public class FileBrowserTab: Identifiable {
    public struct Snapshot: Codable, Sendable, Hashable {
        public let id: UUID
        public let path: String
        public let includeHidden: Bool
        public let expanded: [String]
        public let selectedFile: String?
        public var hostOwned: Bool? = nil
    }

    public let id: UUID
    public private(set) var hostTab: HostFileTab?
    public private(set) var sourcePaneID: String?
    public private(set) var path: String?
    private var requestedPath: String?
    public var pathInput: String
    public var includeHidden = false
    public var query = ""
    public var searchMode = FileBrowserSearchMode.name
    public var expanded: Set<String> = []
    public var selectedFile: String? {
        didSet {
            if oldValue != selectedFile {
                openSession.cancel()
            }
        }
    }

    public var lastSelectedAt = Date.distantPast
    public var refresh = 0 {
        didSet {
            if oldValue != refresh {
                openSession.cancel()
            }
        }
    }

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
    @ObservationIgnored let previewSession = FileBrowserPreviewSession()
    let openSession = FileBrowserOpenSession()
    let uploadSession = FileBrowserUploadSession()

    public init(id: UUID = UUID(), path: String? = nil, sourcePaneID: String? = nil) {
        self.id = id
        self.path = path
        self.requestedPath = path
        self.pathInput = path ?? ""
        self.sourcePaneID = sourcePaneID
        previewSession.onEvict = { [weak self] in
            self?.previewData = nil
            self?.previewURL = nil
        }
    }

    isolated deinit {
        uploadSession.cancel()
        openSession.cancel()
        previewSession.close()
    }

    public var title: String {
        "Files · \(path.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? "/" : $0 } ?? "…")"
    }

    public var listing: FileBrowserListing? {
        path.flatMap { listings[$0] }
    }

    public static func sourcePaneID(in paneIDs: [String], focusedPaneID: String?, activePaneID: String?) -> String? {
        if let focusedPaneID, paneIDs.contains(focusedPaneID) {
            return focusedPaneID
        }
        if let activePaneID, paneIDs.contains(activePaneID) {
            return activePaneID
        }
        return paneIDs.first
    }

    public var snapshot: Snapshot? {
        path.map { .init(id: id, path: $0, includeHidden: includeHidden, expanded: expanded.sorted(), selectedFile: selectedFile, hostOwned: hostTab == nil ? nil : true) }
    }

    public convenience init(hostTab: HostFileTab) {
        self.init(id: hostTab.id, path: hostTab.initialDirectory, sourcePaneID: hostTab.sourcePaneID)
        self.hostTab = hostTab
    }

    public func updateHostTab(_ tab: HostFileTab) {
        guard tab.id == id else { return }
        hostTab = tab
        sourcePaneID = tab.sourcePaneID
    }

    public convenience init(snapshot: Snapshot, sourcePaneID: String? = nil) {
        self.init(id: snapshot.id, path: snapshot.path, sourcePaneID: sourcePaneID)
        restoreNavigation(snapshot)
    }

    /// Restore private navigation only after the caller verifies the source.
    /// Host ownership and request/download state are deliberately kept live.
    public func restoreNavigation(_ snapshot: Snapshot) {
        guard snapshot.id == id else { return }
        if path != snapshot.path {
            navigate(snapshot.path)
        }
        includeHidden = snapshot.includeHidden
        expanded = Set(snapshot.expanded)
        selectedFile = snapshot.selectedFile
    }

    public func restoreSourcePane(_ paneID: String?) {
        guard hostTab == nil else { return }
        sourcePaneID = paneID
    }

    public func releasePreview() {
        openSession.cancel()
        previewID = UUID()
        previewSession.close()
        previewData = nil
        previewURL = nil
        isPreviewLoading = false
    }

    public func cancelUploads() {
        uploadSession.cancel()
    }

    /// Closing a tab or losing its Host also stops writes, including while hidden.
    public func releaseResources() {
        cancelUploads()
        releasePreview()
    }

    func suspendPreview() {
        guard !previewSession.hasContent else { return }
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
        let connectionID: UUID?
        let unavailable: String?
    }

    public func loadKey(source: FileBrowserSource) -> LoadKey {
        .init(
            path: requestedPath,
            query: query,
            mode: searchMode,
            hidden: includeHidden,
            refresh: refresh,
            sourceID: source.id,
            connectionID: source.connectionID,
            unavailable: source.unavailableReason
        )
    }

    public func navigate(_ path: String?) {
        previewSession.close()
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

    public func openTerminalFile(_ destination: TerminalFileDestination, paneID: String) {
        if hostTab?.resourceSessionID == nil {
            sourcePaneID = paneID
        }
        navigate(destination.directory)
        selectedFile = destination.file
    }

    /// A file URL here identifies a path on the captured source, never a Viewer-local file.
    func openMarkdownLink(_ url: URL, from documentPath: String, source: FileBrowserSource) async throws {
        try Task.checkCancellation()
        guard selectedFile == documentPath else { return }
        let navigationID = loadID
        let selectionID = previewID
        let target = url.absoluteURL
        guard
            target.isFileURL, target.host == nil || target.host == "" || target.host == "localhost",
            target.path.hasPrefix("/"), !target.path.contains("\0") else {
            throw FileBrowserError.message("This link does not identify a file on the source Host.")
        }
        // A heading link within this document must not reload the preview.
        guard target.path != (preview?.path ?? documentPath) else { return }
        if let reason = source.unavailableReason {
            throw FileBrowserError.message(reason)
        }
        guard case let .info(info) = try await source.request(.info(path: target.path)) else {
            throw FileBrowserError.message("The Host returned no information for this link.")
        }
        try Task.checkCancellation()
        guard selectedFile == documentPath, loadID == navigationID, previewID == selectionID else { return }
        if info.kind == .directory {
            navigate(info.path)
        } else {
            navigate((info.path as NSString).deletingLastPathComponent)
            selectedFile = info.path
        }
    }

    /// A closed/moved source must not attach to a later window or pane with the same ID.
    public func reconcileSource(windows: [TmuxWindow]) {
        let panes = windows.flatMap(\.panes)
        if let sourcePaneID, !panes.contains(where: { $0.paneId == sourcePaneID }) {
            self.sourcePaneID = nil
        }
    }

    public func load(source: FileBrowserSource) async {
        guard !Task.isCancelled else { return }
        uploadSession.configure(source: source)
        let token = UUID()
        loadID = token
        error = nil
        isLoading = true
        searchResults = nil
        // Reset pages, not expansion, so a refresh never combines different directory revisions.
        listings = [:]
        defer {
            if loadID == token {
                isLoading = false
            }
        }
        do {
            if let reason = source.unavailableReason {
                throw FileBrowserError.message(reason)
            }
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
        catch {
            if loadID == token {
                self.error = error.localizedDescription
            }
        }
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
                listings[directory] = .init(
                    directory: result.directory,
                    homeDirectory: result.homeDirectory,
                    entries: previous.entries + result.entries,
                    nextOffset: result.nextOffset,
                    revision: result.revision
                )
            } else {
                listings[directory] = result
            }
        } catch is CancellationError { }
        catch {
            if token == loadID {
                self.error = error.localizedDescription
            }
        }
    }

    public func loadPreview(source: FileBrowserSource) async {
        openSession.configure(source: source)
        previewSession.configure(.init(sourceID: source.id, connectionID: source.connectionID, path: selectedFile, refresh: refresh))
        let token = UUID()
        previewID = token
        if !previewSession.hasContent {
            preview = nil
            previewData = nil
            previewURL = nil
        }
        previewError = nil
        isPreviewLoading = false
        guard let selectedFile else { return }
        isPreviewLoading = !previewSession.hasContent
        defer {
            if token == previewID {
                isPreviewLoading = false
            }
        }
        do {
            if let reason = source.unavailableReason {
                throw FileBrowserError.message(reason)
            }
            guard case let .info(info) = try await source.request(.info(path: selectedFile)) else {
                throw FileBrowserError.message("Missing file information.")
            }
            try Task.checkCancellation()
            guard token == previewID else { return }
            previewSession.acceptRevision(info.revision)
            preview = info
            if previewSession.hasContent {
                return
            }
            // These previews own their bounded transfer/player after metadata validation.
            if
                FileBrowserOfficeDocument.supports(path: selectedFile)
                || (source.localFileURL == nil && FileBrowserVideo.supports(path: selectedFile)) {
                return
            }
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
            if let localPreview = source.localPreview {
                data = try await localPreview(info)
                guard data.count == info.size else { throw FileBrowserError.message("File changed. Refresh its preview.") }
            } else {
                data.reserveCapacity(info.size)
                while data.count < info.size {
                    try Task.checkCancellation()
                    guard
                        case let .chunk(chunk) = try await source.request(.read(path: info.path, offset: data.count, revision: info.revision)),
                        chunk.path == info.path, chunk.revision == info.revision, chunk.offset == data.count,
                        !chunk.data.isEmpty, chunk.data.count <= FileBrowserLimits.chunkBytes, data.count + chunk.data.count <= info.size else {
                        throw FileBrowserError.message("File changed or the Host returned an invalid file chunk. Refresh its preview.")
                    }
                    data.append(chunk.data)
                }
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
        catch {
            if token == previewID {
                previewSession.evict()
                previewError = error.localizedDescription
            }
        }
    }

    static func isMedia(path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}
