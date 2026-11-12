import CtrlxEncryption
import Foundation

public enum SharedItemKind: String, Codable, Sendable {
    case photo
    case file
}

public struct SharedInboxItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let batchID: UUID
    public let name: String
    public let kind: SharedItemKind
    public let size: Int
    public let url: URL
}

public struct ShareInboxError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// The extension publishes complete batches by rename. Only the containing app
/// consumes them; every batch has its own manifest, so writers never share one.
public actor ShareInboxStore {
    public static let maximumItems = 5
    public static let maximumFileBytes = 1_024 * 1_024 * 1_024
    public static let maximumPhotoBytes = 20 * 1_024 * 1_024
    public let root: URL

    struct Entry: Codable {
        let id: UUID
        let name: String
        let kind: SharedItemKind
        let size: Int
    }

    private struct Manifest: Codable {
        let createdAt: Date
        let items: [Entry]
    }

    public init(root: URL) {
        self.root = root
    }

    public static func appGroupStore() throws -> ShareInboxStore {
        #if os(iOS) || os(macOS)
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier) else {
                throw ShareInboxError("Shared Items is unavailable in this installation of CtrlX. Reinstall a build with system sharing support.")
            }
            return ShareInboxStore(root: container.appendingPathComponent("ShareInbox", isDirectory: true))
        #else
            throw ShareInboxError("System sharing is only available on Apple platforms.")
        #endif
    }

    public func begin() throws -> UUID {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try removeAbandonedDrafts()
        let id = UUID()
        try FileManager.default.createDirectory(at: draft(id), withIntermediateDirectories: false)
        return id
    }

    public func stagingDirectory(_ batch: UUID) -> URL {
        draft(batch)
    }

    public func commit(_ batch: UUID, entries: [PreparedSharedItem]) throws {
        guard !entries.isEmpty, entries.count <= Self.maximumItems, Set(entries.map(\.id)).count == entries.count else {
            throw ShareInboxError("Share between 1 and \(Self.maximumItems) items at a time.")
        }
        var total = 0
        for entry in entries {
            guard Self.validName(entry.name), entry.size >= 0, entry.size <= Self.limit(entry.kind) else {
                throw ShareInboxError("A shared item has an invalid name or size.")
            }
            total += entry.size
            guard total <= Self.maximumFileBytes else { throw ShareInboxError("Share no more than 1 GiB at a time.") }
            try Self.validateFile(draft(batch).appendingPathComponent(entry.id.uuidString).appendingPathComponent(entry.name), expectedSize: entry.size)
        }
        let manifest = Manifest(createdAt: Date(), items: entries.map { Entry(id: $0.id, name: $0.name, kind: $0.kind, size: $0.size) })
        try JSONEncoder().encode(manifest).write(to: draft(batch).appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.moveItem(at: draft(batch), to: root.appendingPathComponent(batch.uuidString, isDirectory: true))
    }

    public func cancel(_ batch: UUID) throws {
        let directory = draft(batch)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func pending() throws -> [SharedInboxItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try removeAbandonedDrafts()
        var batches: [(Date, [SharedInboxItem])] = []
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard let batchID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try Self.validateFile(manifestURL, maximumSize: 64 * 1_024)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            let entries = manifest.items
            guard entries.count <= Self.maximumItems, Set(entries.map(\.id)).count == entries.count else {
                throw ShareInboxError("A shared batch is invalid.")
            }
            var items: [SharedInboxItem] = []
            for entry in entries {
                guard Self.validName(entry.name), entry.size >= 0, entry.size <= Self.limit(entry.kind) else {
                    throw ShareInboxError("A shared item is invalid.")
                }
                let url = directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent(entry.name)
                // Acknowledgements unlink payloads. A crash between unlink and
                // removing the now-empty batch must not resurrect sent items.
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try Self.validateFile(url, expectedSize: entry.size)
                items.append(.init(id: entry.id, batchID: batchID, name: entry.name, kind: entry.kind, size: entry.size, url: url))
            }
            batches.append((manifest.createdAt, items))
        }
        return batches.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    public func remove(_ item: SharedInboxItem) throws {
        let directory = root.appendingPathComponent(item.batchID.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(item.id.uuidString)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { UUID(uuidString: $0) != nil }
        if remaining.isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func draft(_ id: UUID) -> URL {
        root.appendingPathComponent(".pending-\(id.uuidString)", isDirectory: true)
    }

    private func removeAbandonedDrafts() throws {
        for directory in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey]) {
            guard directory.lastPathComponent.hasPrefix(".pending-"), UUID(uuidString: String(directory.lastPathComponent.dropFirst(9))) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
            if values.isSymbolicLink != true, let modified = values.contentModificationDate, modified < Date().addingTimeInterval(-86_400) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func limit(_ kind: SharedItemKind) -> Int {
        kind == .photo ? maximumPhotoBytes : maximumFileBytes
    }

    static func validateFile(_ url: URL, expectedSize: Int? = nil, maximumSize: Int = maximumFileBytes) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard
            values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw ShareInboxError("The shared item is not a supported regular file.")
        }
        guard size <= maximumSize else {
            throw ShareInboxError("The shared file is too large. Limit: \(maximumSize.formatted(.byteCount(style: .binary))).")
        }
        if let expectedSize, expectedSize != size {
            throw ShareInboxError("The shared file changed. Share it again to make a new copy.")
        }
    }
}

public struct PreparedSharedItem: Sendable {
    public let id: UUID
    public let name: String
    public let kind: SharedItemKind
    public let size: Int

    /// Run within the provider's file-representation callback: its URL is only
    /// valid until that callback returns. Copies are streamed with a hard bound.
    public static func copy(from source: URL, to directory: URL, name: String, kind: SharedItemKind, maximumBytes: Int? = nil) throws -> Self {
        guard ShareInboxStore.validName(name) else { throw ShareInboxError("The shared filename is invalid.") }
        let limit = min(ShareInboxStore.limit(kind), maximumBytes ?? ShareInboxStore.maximumFileBytes)
        let granted = source.startAccessingSecurityScopedResource()
        defer {
            if granted {
                source.stopAccessingSecurityScopedResource()
            }
        }
        try ShareInboxStore.validateFile(source, maximumSize: limit)
        let id = UUID()
        let itemDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: false)
        let destination = itemDirectory.appendingPathComponent(name)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ShareInboxError("Unable to prepare the shared file.") }
        let output = try FileHandle(forWritingTo: destination)
        var complete = false
        defer {
            try? output.close()
            if !complete {
                try? FileManager.default.removeItem(at: itemDirectory)
            }
        }
        var bytes = 0
        while let chunk = try input.read(upToCount: 128 * 1_024), !chunk.isEmpty {
            bytes += chunk.count
            guard bytes <= limit else { throw ShareInboxError("The shared file is too large.") }
            try output.write(contentsOf: chunk)
        }
        try output.close()
        complete = true
        return .init(id: id, name: name, kind: kind, size: bytes)
    }
}
