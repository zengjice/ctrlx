import CtrlxCommon
import CtrlxNetworking
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct FileBrowserClient: Sendable {
    var request: @Sendable (FileBrowserOperation) async throws -> FileBrowserResponse
}

extension FileBrowserClient: DependencyKey {
    static let liveValue = Self(request: { try await HostFileBrowser.shared.request($0) })
}

extension FileBrowserSource {
    static func local(paneID: String?, tmux: TmuxService, windows: MirrorWindowManager) -> Self {
        Self(id: "local", paneID: paneID) { operation in
            @Dependency(FileBrowserClient.self) var client
            var request = operation
            if case let .list(nil, offset, hidden) = operation {
                // Resolve only at open/explicit follow. A later cd must not move an
                // already open browser, and each split must use its own pane ID.
                var candidates: [String] = []
                if let paneID, paneID.hasPrefix("%"), paneID.dropFirst().allSatisfy(\.isNumber) {
                    if let path = windows.paneStates[paneID]?.agentSession?.detectedProjectPath {
                        candidates.append(path)
                    }
                    let result = try await tmux.runTmuxCommand(["display-message", "-p", "-t", paneID, "#{pane_current_path}"])
                    if result.isSuccess {
                        candidates.append(result.stdoutString.trimmingCharacters(in: .newlines))
                    }
                }
                candidates.append("~/")
                @Dependency(SessionDirectoryClient.self) var directories
                var directory: String?
                for candidate in candidates {
                    do { directory = try await directories.resolve(candidate); break }
                    catch is CancellationError { throw CancellationError() }
                    catch { continue } // A closed pane/deleted cwd falls back to Home.
                }
                guard let directory else { throw FileBrowserError.message("The Host home directory is unavailable.") }
                request = .list(path: directory, offset: offset, includeHidden: hidden)
            }
            return try await client.request(request)
        }
    }
}

/// Separate from tmux and UI actors: browsing cannot block a terminal input queue.
actor HostFileBrowser {
    static let shared = HostFileBrowser()
    private let files = FileManager.default

    func request(_ request: FileBrowserOperation) throws -> FileBrowserResponse {
        try Task.checkCancellation()
        switch request {
        case let .list(path, offset, hidden):
            return try .listing(list(path: path ?? "~/", offset: offset, hidden: hidden))
        case let .info(path):
            return try .info(entry(path: resolve(path)))
        case let .read(path, offset, revision):
            let path = try resolve(path)
            let data = try read(path: path, offset: offset, revision: revision)
            return .chunk(.init(path: path, revision: revision, offset: offset, data: data))
        case let .search(path, query, mode, hidden):
            return try .search(search(path: resolve(path), query: query, mode: mode, hidden: hidden))
        }
    }

    private func resolve(_ input: String) throws -> String {
        guard input.utf8.count <= 4096,
              let path = SessionDirectoryPath.expanded(input, hostHome: files.homeDirectoryForCurrentUser.path)
        else { throw FileBrowserError.message("Enter an absolute Host path or ~/….") }
        return (path as NSString).standardizingPath
    }

    private func metadata(_ path: String) throws -> stat {
        var value = stat()
        guard stat(path, &value) == 0 else { throw posixError(path) }
        return value
    }

    private func revision(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    private func entry(path: String) throws -> FileBrowserEntry {
        let value = try metadata(path)
        var link = stat()
        let isLink = lstat(path, &link) == 0 && (link.st_mode & S_IFMT) == S_IFLNK
        let kind: FileBrowserKind
        if (value.st_mode & S_IFMT) == S_IFDIR { kind = .directory }
        else if (value.st_mode & S_IFMT) != S_IFREG { kind = .unsupported }
        else { kind = Self.kind(for: path) }
        return .init(path: path, name: (path as NSString).lastPathComponent, kind: kind,
                     size: max(0, Int(value.st_size)), revision: revision(value), isSymbolicLink: isLink)
    }

    private func list(path: String, offset: Int, hidden: Bool) throws -> FileBrowserListing {
        let path = try resolve(path)
        guard offset >= 0, offset <= FileBrowserLimits.maximumDirectoryEntries else {
            throw FileBrowserError.message("Invalid directory page.")
        }
        let before = try metadata(path)
        guard before.st_mode & S_IFMT == S_IFDIR else { throw FileBrowserError.message("Not a Host directory: \(path)") }
        guard files.isReadableFile(atPath: path), files.isExecutableFile(atPath: path) else {
            throw FileBrowserError.message("Cannot read Host directory: \(path)")
        }
        guard let enumerator = files.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                               options: hidden ? [.skipsSubdirectoryDescendants] : [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else {
            throw FileBrowserError.message("Cannot read Host directory: \(path)")
        }
        var entries: [FileBrowserEntry] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard entries.count < FileBrowserLimits.maximumDirectoryEntries else {
                throw FileBrowserError.message("Directory is too large. Open a subfolder directly.")
            }
            // Unreadable/broken children do not make readable siblings inaccessible.
            if let item = try? entry(path: (path as NSString).appendingPathComponent(url.lastPathComponent)) { entries.append(item) }
        }
        entries.sort {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard revision(before) == revision(try metadata(path)) else { throw FileBrowserError.message("Directory changed. Refresh and try again.") }
        var page: [FileBrowserEntry] = []
        var bytes = 0
        for item in entries.dropFirst(offset).prefix(FileBrowserLimits.directoryPageSize) {
            let count = try JSONEncoder().encode(item).count
            guard bytes + count <= 128 * 1024 else { break }
            page.append(item)
            bytes += count
        }
        let next = offset + page.count
        return .init(directory: path, homeDirectory: files.homeDirectoryForCurrentUser.path, entries: page,
                     nextOffset: next < entries.count ? next : nil, revision: revision(before))
    }

    private func read(path: String, offset: Int, revision expected: String) throws -> Data {
        guard offset >= 0 else { throw FileBrowserError.message("Invalid file offset.") }
        // O_NONBLOCK + fstat avoids hanging on a FIFO or a replaced special file.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw FileBrowserError.message("Only regular files can be previewed.")
        }
        guard revision(before) == expected else { throw FileBrowserError.message("File changed. Refresh its preview.") }
        let kind = Self.kind(for: path)
        let limit = kind == .text || kind == .markdown ? FileBrowserLimits.maximumTextBytes : FileBrowserLimits.maximumPreviewBytes
        guard kind != .unsupported, before.st_size <= limit, offset <= before.st_size else {
            throw FileBrowserError.message("This file is too large or its format cannot be previewed.")
        }
        var data = Data(count: min(FileBrowserLimits.chunkBytes, Int(before.st_size) - offset))
        let count = data.withUnsafeMutableBytes { bytes in
            pread(fd, bytes.baseAddress, bytes.count, off_t(offset))
        }
        guard count >= 0 else { throw posixError(path) }
        data.count = count
        var after = stat()
        guard fstat(fd, &after) == 0, revision(after) == expected,
              revision(try metadata(path)) == expected else { throw FileBrowserError.message("File changed. Refresh its preview.") }
        return data
    }

    private func search(path: String, query: String, mode: FileBrowserSearchMode, hidden: Bool) throws -> FileBrowserSearchResults {
        guard !query.isEmpty, query.utf8.count <= 512 else { throw FileBrowserError.message("Enter a search of 1–512 bytes.") }
        guard try entry(path: path).kind == .directory,
              files.isReadableFile(atPath: path), files.isExecutableFile(atPath: path),
              let enumerator = files.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isSymbolicLinkKey],
                                               options: hidden ? [] : [.skipsHiddenFiles]) else {
            throw FileBrowserError.message("Cannot search Host directory: \(path)")
        }
        let deadline = ContinuousClock.now + .seconds(2)
        var scanned = 0
        var bytesRead = 0
        var matches: [FileBrowserSearchMatch] = []
        var truncated = false
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard scanned < FileBrowserLimits.maximumSearchEntries, matches.count < FileBrowserLimits.maximumSearchResults,
                  bytesRead < 16 * 1024 * 1024, ContinuousClock.now < deadline else { truncated = true; break }
            scanned += 1
            guard let item = try? entry(path: url.path) else { continue }
            if item.isSymbolicLink { enumerator.skipDescendants() }
            if mode == .name {
                if item.name.localizedCaseInsensitiveContains(query) { matches.append(.init(entry: item)) }
            } else if !item.isSymbolicLink, item.kind == .text || item.kind == .markdown,
                      item.size <= FileBrowserLimits.maximumTextBytes,
                      let data = try? searchData(item) {
                bytesRead += data.count
                guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { continue }
                // One hit per file keeps response size and list identity bounded.
                if let line = text.components(separatedBy: .newlines).enumerated().first(where: { $0.element.localizedCaseInsensitiveContains(query) }) {
                    matches.append(.init(entry: item, lineNumber: line.offset + 1, lineText: String(line.element.prefix(200))))
                }
            }
        }
        // Deep paths can exceed the frame budget even with only 200 matches.
        while try JSONEncoder().encode(matches).count > 128 * 1024 { matches.removeLast(); truncated = true }
        return .init(matches: matches, isTruncated: truncated)
    }

    private func searchData(_ item: FileBrowserEntry) throws -> Data {
        var data = Data()
        while data.count < item.size {
            try Task.checkCancellation()
            let chunk = try read(path: item.path, offset: data.count, revision: item.revision)
            guard !chunk.isEmpty else { throw FileBrowserError.message("File changed during search.") }
            data.append(chunk)
        }
        return data
    }

    static func kind(for path: String) -> FileBrowserKind {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp": .image
        case "pdf": .pdf
        case "zip", "gz", "dmg", "app", "mp4", "mov", "mp3", "a", "dylib", "woff", "ttf", "sqlite", "db": .unsupported
        default: .text // UTF-8/NUL validation rejects unknown binary formats.
        }
    }

    private func posixError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
    }
}
