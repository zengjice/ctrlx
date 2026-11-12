import Foundation
import Testing
@testable import CtrlxShare

struct ShareInboxStoreTests {
    private func fixture() throws -> (URL, ShareInboxStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source")
        try Data("shared payload".utf8).write(to: source)
        return (root, ShareInboxStore(root: root.appendingPathComponent("inbox")), source)
    }

    @Test("A provider's temporary file is copied before publication, preserving names and selected order")
    func atomicReceive() async throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.begin()
        let directory = await store.stagingDirectory(batch)
        let first = try PreparedSharedItem.copy(from: source, to: directory, name: "相片.heic", kind: .photo)
        let second = try PreparedSharedItem.copy(from: source, to: directory, name: "report.pdf", kind: .file)
        #expect(try await store.pending().isEmpty)
        try FileManager.default.removeItem(at: source)
        try await store.commit(batch, entries: [first, second])
        let items = try await store.pending()
        #expect(items.map(\.name) == ["相片.heic", "report.pdf"])
        #expect(items.map(\.kind) == [.photo, .file])
        #expect(items.map { $0.url.lastPathComponent } == items.map(\.name))
        for item in items {
            #expect(try Data(contentsOf: item.url) == Data("shared payload".utf8))
        }
    }

    @Test("Acknowledging one file survives app restart without dropping the rest of the batch")
    func acknowledgement() async throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.begin()
        let directory = await store.stagingDirectory(batch)
        let entries = try ["one.pdf", "two.pdf"].map { try PreparedSharedItem.copy(from: source, to: directory, name: $0, kind: .file) }
        try await store.commit(batch, entries: entries)
        let items = try await store.pending()
        try await store.remove(#require(items.first))
        let restarted = ShareInboxStore(root: root.appendingPathComponent("inbox"))
        let remaining = try await restarted.pending()
        #expect(remaining.map(\.name) == ["two.pdf"])
        try await restarted.remove(#require(remaining.first))
        #expect(try await store.pending().isEmpty)
    }

    @Test("Equal filenames do not overwrite another shared item")
    func equalNames() async throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.begin()
        let directory = await store.stagingDirectory(batch)
        let entries = try (0..<2).map { _ in try PreparedSharedItem.copy(from: source, to: directory, name: "photo.png", kind: .photo) }
        try await store.commit(batch, entries: entries)
        let items = try await store.pending()
        #expect(items.count == 2 && Set(items.map(\.url)).count == 2)
    }

    @Test("Invalid names, symbolic links and oversized sources are rejected before publication")
    func rejectUnsafeSources() async throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.begin()
        let directory = await store.stagingDirectory(batch)
        for name in ["../outside", "folder/file", ".", "\nfile"] {
            #expect(throws: (any Error).self) { try PreparedSharedItem.copy(from: source, to: directory, name: name, kind: .file) }
        }
        let link = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try PreparedSharedItem.copy(from: link, to: directory, name: "link", kind: .file) }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ShareInboxStore.maximumFileBytes + 1))
        try handle.close()
        #expect(throws: (any Error).self) { try PreparedSharedItem.copy(from: source, to: directory, name: "large", kind: .file) }
        try await store.cancel(batch)
        #expect(try await store.pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Crash leftovers expire without removing current or committed shares")
    func abandonedDrafts() async throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try await store.begin()
        let oldDirectory = await store.stagingDirectory(old)
        _ = try PreparedSharedItem.copy(from: source, to: oldDirectory, name: "old", kind: .file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: oldDirectory.path)
        let current = try await store.begin()
        let directory = await store.stagingDirectory(current)
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        let entry = try PreparedSharedItem.copy(from: source, to: directory, name: "keep", kind: .file)
        try await store.commit(current, entries: [entry])
        #expect(try await store.pending().map(\.name) == ["keep"])
    }

    @Test("The remaining batch allowance is enforced before copying another file")
    func batchAllowance() async throws {
        let (root, store, source) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = try await store.begin()
        let directory = await store.stagingDirectory(batch)
        #expect(throws: (any Error).self) {
            try PreparedSharedItem.copy(from: source, to: directory, name: "over-limit", kind: .file, maximumBytes: 1)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try await store.cancel(batch)
    }
}
