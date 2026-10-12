import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation
import os

@DependencyClient
public struct FileBrowserDownloadClient: Sendable {
    public var begin: @Sendable (_ name: String, _ size: Int) async throws -> URL
    public var append: @Sendable (_ url: URL, _ data: Data) async throws -> Void
    public var finish: @Sendable (_ url: URL) async throws -> Void
    public var discard: @Sendable (_ url: URL) async -> Void
    public var retain: @Sendable (_ url: URL) async throws -> FileBrowserDownloadLease? = { _ in nil }
    public var maintain: @Sendable () async -> Void = { }
}

/// Keeps a completed copy alive while a native preview is using it.
final public class FileBrowserDownloadLease: Sendable {
    private let releaseAction: @Sendable () async -> Void

    init(release: @escaping @Sendable () async -> Void) {
        self.releaseAction = release
    }

    func release() async {
        await releaseAction()
    }

    deinit {
        let action = releaseAction
        Task { await action() }
    }
}

extension FileBrowserDownloadClient: DependencyKey {
    public static let liveValue = live()

    /// A separate root keeps native acceptance runs away from the user's cache.
    public static func live(root: URL? = nil) -> Self {
        let files = FileBrowserDownloads(root: root)
        return Self(
            begin: { try await files.begin(name: $0, size: $1) },
            append: { try await files.append($1, to: $0) },
            finish: { try await files.finish($0) },
            discard: { await files.discard($0) },
            retain: { try await files.retain($0) },
            maintain: { await files.maintain() }
        )
    }
}

/// A chunk at a time, off the UI actor. Successful copies outlive the presenting
/// view because the receiving app may keep reading them. Retain unused copies
/// for one day; never evict an active preview merely to make room for a download.
actor FileBrowserDownloads {
    static let maximumCacheBytes = 2 * 1_024 * 1_024 * 1_024
    static let retention: TimeInterval = 24 * 60 * 60
    static let maintenanceInterval: TimeInterval = 60 * 60

    private struct Download {
        let handle: FileHandle
        let expectedBytes: Int
        var writtenBytes = 0
    }

    private let root: URL
    private let files = FileManager.default
    private let maximumBytes: Int
    private let now: @Sendable () -> Date
    private let availableBytes: @Sendable (URL) throws -> Int64?
    private var handles: [URL: Download] = [:]
    private var leases: [URL: Set<UUID>] = [:]
    private var lastMaintenance: Date?
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "FileDownloads")

    init(
        root: URL? = nil,
        maximumBytes: Int = FileBrowserDownloads.maximumCacheBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        availableBytes: @escaping @Sendable (URL) throws -> Int64? = {
            try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        }
    ) {
        self.root = (root ?? (
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        ).appendingPathComponent("CtrlX/FileBrowserDownloads", isDirectory: true)).standardizedFileURL
        self.maximumBytes = maximumBytes
        self.now = now
        self.availableBytes = availableBytes
    }

    func begin(name: String, size: Int) throws -> URL {
        try Task.checkCancellation()
        guard
            !name.isEmpty, name != ".", name != "..", (name as NSString).lastPathComponent == name,
            size >= 0, size <= FileBrowserLimits.maximumDownloadBytes else {
            throw FileBrowserError.message("Invalid download name or size (maximum 1 GiB).")
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try validateRoot()
        try removeExpiredCopies()
        let used = try cacheBytes()
        guard used <= maximumBytes, size <= maximumBytes - used else {
            throw FileBrowserError.message("The file download cache is full (maximum 2 GiB). Close unused previews and try again after temporary copies expire.")
        }
        // In-flight copies reserve their remaining bytes as well as their disk
        // usage, so concurrent downloads cannot each consume the same free space.
        let reserved = handles.values.reduce(0) { $0 + $1.expectedBytes - $1.writtenBytes }
        if
            let capacity = try availableBytes(root),
            capacity < Int64(size) + Int64(reserved) + 256 * 1_024 * 1_024 {
            throw FileBrowserError.message("Not enough free space to download this file.")
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw FileBrowserError.message("Could not create the downloaded file.")
            }
            handles[url] = try Download(handle: FileHandle(forWritingTo: url), expectedBytes: size)
            try touch(url)
            return url
        } catch {
            discard(url)
            throw error
        }
    }

    func append(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        guard var download = handles[url] else { throw FileBrowserError.message("Download is no longer active.") }
        guard data.count <= download.expectedBytes - download.writtenBytes else {
            throw FileBrowserError.message("Download exceeded its reserved size.")
        }
        try download.handle.write(contentsOf: data)
        download.writtenBytes += data.count
        handles[url] = download
    }

    func finish(_ url: URL) throws {
        guard let download = handles[url] else { throw FileBrowserError.message("Download is no longer active.") }
        guard download.writtenBytes == download.expectedBytes else {
            throw FileBrowserError.message("Download is incomplete.")
        }
        try download.handle.close()
        handles.removeValue(forKey: url)
        try touch(url)
    }

    func retain(_ url: URL) throws -> FileBrowserDownloadLease? {
        guard owns(url) else { return nil } // Local Host originals are not cache copies.
        guard handles[url] == nil, files.fileExists(atPath: url.path) else {
            throw FileBrowserError.message("The downloaded file is no longer available. Download it again.")
        }
        try touch(url)
        let id = UUID()
        leases[url, default: []].insert(id)
        return FileBrowserDownloadLease { await self.release(url, id: id) }
    }

    private func release(_ url: URL, id: UUID) {
        guard leases[url]?.remove(id) != nil else { return }
        guard leases[url]?.isEmpty == true else { return }
        leases.removeValue(forKey: url)
        // Start external-app retention from the last preview/handoff, not from
        // when a potentially long-running download or preview began.
        do { try touch(url) }
        catch { Self.logger.error("Could not renew downloaded file retention: \(error)") }
    }

    func maintain() {
        let date = now()
        if
            let lastMaintenance, date.timeIntervalSince(lastMaintenance) >= 0,
            date.timeIntervalSince(lastMaintenance) < Self.maintenanceInterval { return }
        do {
            try removeExpiredCopies()
            lastMaintenance = date
        } catch {
            Self.logger.error("Could not clean expired file downloads: \(error)")
        }
    }

    func discard(_ url: URL) {
        guard owns(url), leases[url] == nil else { return }
        do {
            if let download = handles.removeValue(forKey: url) { try download.handle.close() }
        } catch {
            Self.logger.error("Could not close incomplete download: \(error)")
        }
        do {
            try files.removeItem(at: url.deletingLastPathComponent())
        } catch {
            Self.logger.error("Could not remove incomplete download: \(error)")
        }
    }

    private func owns(_ url: URL) -> Bool {
        url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root
            && UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil
    }

    private func validateRoot() throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw FileBrowserError.message("Invalid file download cache directory.")
        }
    }

    private func touch(_ url: URL) throws {
        try files.setAttributes([.modificationDate: now()], ofItemAtPath: url.deletingLastPathComponent().path)
    }

    private func directories() throws -> [URL] {
        guard files.fileExists(atPath: root.path) else { return [] }
        try validateRoot()
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { directory in
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return UUID(uuidString: directory.lastPathComponent) != nil
                    && values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private func removeExpiredCopies() throws {
        let active = Set((Array(handles.keys) + Array(leases.keys)).map { $0.deletingLastPathComponent().standardizedFileURL.path })
        for directory in try directories() {
            guard
                !active.contains(directory.standardizedFileURL.path),
                let date = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                date < now().addingTimeInterval(-Self.retention) else { continue }
            try files.removeItem(at: directory)
        }
    }

    private func cacheBytes() throws -> Int {
        var bytes = handles.values.reduce(0) { $0 + $1.expectedBytes }
        let active = Set(handles.keys.map { $0.standardizedFileURL.path })
        for directory in try directories() {
            for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                guard !active.contains(file.standardizedFileURL.path) else { continue }
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    bytes += values.fileSize ?? 0
                }
            }
        }
        return bytes
    }
}
