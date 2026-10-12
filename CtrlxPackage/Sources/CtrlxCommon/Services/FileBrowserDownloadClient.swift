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
}

extension FileBrowserDownloadClient: DependencyKey {
    public static let liveValue: Self = {
        let files = FileBrowserDownloads()
        return Self(begin: { try await files.begin(name: $0, size: $1) },
                    append: { try await files.append($1, to: $0) },
                    finish: { try await files.finish($0) },
                    discard: { await files.discard($0) })
    }()
}

/// A chunk at a time, off the UI actor. Successful copies outlive the presenting
/// view because the receiving app may keep reading them; purge after one day.
actor FileBrowserDownloads {
    private let root: URL
    private let files = FileManager.default
    private var handles: [URL: FileHandle] = [:]
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "FileDownloads")

    init(root: URL? = nil) {
        self.root = root ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("CtrlX/FileBrowserDownloads", isDirectory: true)
    }

    func begin(name: String, size: Int) throws -> URL {
        try Task.checkCancellation()
        guard !name.isEmpty, name != ".", name != "..", (name as NSString).lastPathComponent == name,
              size >= 0, size <= FileBrowserLimits.maximumDownloadBytes else {
            throw FileBrowserError.message("Invalid download name or size (maximum 1 GiB).")
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        removeExpiredCopies()
        if let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity < Int64(size) + 256 * 1_024 * 1_024 {
            throw FileBrowserError.message("Not enough free space to download this file.")
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw FileBrowserError.message("Could not create the downloaded file.")
            }
            handles[url] = try FileHandle(forWritingTo: url)
            return url
        } catch {
            discard(url)
            throw error
        }
    }

    func append(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        guard let handle = handles[url] else { throw FileBrowserError.message("Download is no longer active.") }
        try handle.write(contentsOf: data)
    }

    func finish(_ url: URL) throws {
        guard let handle = handles.removeValue(forKey: url) else { throw FileBrowserError.message("Download is no longer active.") }
        try handle.close()
    }

    func discard(_ url: URL) {
        guard url.deletingLastPathComponent().deletingLastPathComponent() == root else { return }
        do {
            if let handle = handles.removeValue(forKey: url) { try handle.close() }
        } catch {
            Self.logger.error("Could not close incomplete download: \(error)")
        }
        do {
            try files.removeItem(at: url.deletingLastPathComponent())
        } catch {
            Self.logger.error("Could not remove incomplete download: \(error)")
        }
    }

    private func removeExpiredCopies() {
        do {
            // Directory enumeration can return absolute URLs while appended
            // URLs retain a base; compare filesystem paths, not URL identity.
            let active = Set(handles.keys.map { $0.deletingLastPathComponent().resolvingSymlinksInPath().path })
            for directory in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
                guard !active.contains(directory.resolvingSymlinksInPath().path), let date = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date < Date().addingTimeInterval(-24 * 60 * 60) else { continue }
                try files.removeItem(at: directory)
            }
        } catch {
            Self.logger.error("Could not clean expired file downloads: \(error)")
        }
    }
}
