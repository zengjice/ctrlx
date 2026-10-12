import ConcurrencyExtras
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("File browser download cache lifecycle")
struct FileBrowserCacheTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-cache-test-\(UUID())", isDirectory: true)
    }

    private func complete(_ files: FileBrowserDownloads, size: Int = 6) async throws -> URL {
        let url = try await files.begin(name: "preview.pdf", size: size)
        try await files.append(Data(repeating: 1, count: size), to: url)
        try await files.finish(url)
        return url
    }

    @Test("A native acceptance client writes only under its injected cache root")
    func isolatedClient() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = FileBrowserDownloadClient.live(root: root)
        let url = try await client.begin("preview.pdf", 2)
        #expect(url.deletingLastPathComponent().deletingLastPathComponent() == root)
        try await client.append(url, Data([1, 2]))
        try await client.finish(url)
        let lease = try #require(try await client.retain(url))
        await client.maintain()
        #expect(try Data(contentsOf: url) == Data([1, 2]))
        await lease.release()
        await client.discard(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Startup removes expired copies and crash leftovers without another download")
    func startupMaintenance() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockIsolated(Date())
        let files = FileBrowserDownloads(root: root, now: { clock.value })
        let complete = try await complete(files)
        // Construct a previous-process partial copy; current-process downloads
        // must remain registered and protected instead.
        let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try Data([1]).write(to: orphan.appendingPathComponent("partial"))
        clock.withValue { $0.addTimeInterval(25 * 60 * 60) }
        let restarted = FileBrowserDownloads(root: root, now: { clock.value })
        await restarted.maintain()
        #expect(!FileManager.default.fileExists(atPath: complete.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test("Quota reserves concurrent downloads and refuses to evict recent external-app copies")
    func quotaAndReservation() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockIsolated(Date())
        let files = FileBrowserDownloads(root: root, maximumBytes: 10, now: { clock.value })
        let first = try await files.begin(name: "a.mp4", size: 6)
        await #expect(throws: FileBrowserError.self) { try await files.begin(name: "b.mp4", size: 5) }
        try await files.append(Data(repeating: 1, count: 6), to: first)
        try await files.finish(first)
        await #expect(throws: FileBrowserError.self) { try await files.begin(name: "b.mp4", size: 5) }
        #expect(FileManager.default.fileExists(atPath: first.path))
        clock.withValue { $0.addTimeInterval(25 * 60 * 60) }
        let next = try await files.begin(name: "b.mp4", size: 5)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        await files.discard(next)
    }

    @Test("One preview closing cannot release another preview's cache ownership")
    func previewLeases() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockIsolated(Date())
        let files = FileBrowserDownloads(root: root, maximumBytes: 10, now: { clock.value })
        let url = try await complete(files)
        let first = try #require(try await files.retain(url))
        let second = try #require(try await files.retain(url))
        await first.release()
        clock.withValue { $0.addTimeInterval(25 * 60 * 60) }
        await files.maintain()
        #expect(FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: FileBrowserError.self) { try await files.begin(name: "b.mp4", size: 6) }
        await second.release()
        await files.maintain()
        #expect(FileManager.default.fileExists(atPath: url.path), "Releasing restarts the external-app grace period")
        clock.withValue { $0.addTimeInterval(25 * 60 * 60) }
        await files.maintain()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Long-running active downloads survive expiry and finish with a fresh retention period")
    func downloadLifetime() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockIsolated(Date())
        let files = FileBrowserDownloads(root: root, now: { clock.value })
        let url = try await files.begin(name: "large.mp4", size: 2)
        clock.withValue { $0.addTimeInterval(25 * 60 * 60) }
        await files.maintain()
        #expect(FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: FileBrowserError.self) { try await files.finish(url) }
        await #expect(throws: FileBrowserError.self) { try await files.append(Data([1, 2, 3]), to: url) }
        try await files.append(Data([1, 2]), to: url)
        try await files.finish(url)
        clock.withValue { $0.addTimeInterval(60 * 60) }
        await files.maintain()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Low-space checks include other downloads' unwritten reservations")
    func lowSpace() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let capacity = LockIsolated(Int64(256 * 1_024 * 1_024 + 9))
        let files = FileBrowserDownloads(root: root, availableBytes: { _ in capacity.value })
        let active = try await files.begin(name: "a.mp4", size: 6)
        await #expect(throws: FileBrowserError.self) { try await files.begin(name: "b.mp4", size: 4) }
        await files.discard(active)
        let next = try await files.begin(name: "b.mp4", size: 4)
        await files.discard(next)
        capacity.setValue(0)
        await #expect(throws: FileBrowserError.self) { try await files.begin(name: "c.mp4", size: 1) }
    }

    @Test("Maintenance is throttled across foreground windows, but a new process always checks")
    func throttling() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockIsolated(Date())
        let files = FileBrowserDownloads(root: root, now: { clock.value })
        let url = try await complete(files)
        clock.withValue { $0.addTimeInterval(24 * 60 * 60 - 1) }
        await files.maintain()
        clock.withValue { $0.addTimeInterval(2) }
        await files.maintain()
        #expect(FileManager.default.fileExists(atPath: url.path))
        let restarted = FileBrowserDownloads(root: root, now: { clock.value })
        await restarted.maintain()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Only owned UUID copies are removed; originals, unknown folders and symlinks are untouched")
    func cleanupBoundary() async throws {
        let parent = root()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("cache", isDirectory: true)
        let original = parent.appendingPathComponent("original", isDirectory: true)
        let unknown = root.appendingPathComponent("user-saved", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let originalFile = original.appendingPathComponent("movie.mp4")
        try Data([1, 2]).write(to: originalFile)
        let link = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let files = FileBrowserDownloads(root: root, now: { Date().addingTimeInterval(48 * 60 * 60) })
        await files.maintain()
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(try Data(contentsOf: originalFile) == Data([1, 2]))
        #expect(try await files.retain(originalFile) == nil)
        await files.discard(originalFile)
        #expect(FileManager.default.fileExists(atPath: originalFile.path))
    }

    @MainActor
    @Test("The transfer keeps its verified copy leased for the preview lifetime")
    func transferOwnership() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockIsolated(Date())
        let files = FileBrowserDownloads(root: root, now: { clock.value })
        let entry = FileBrowserEntry(path: "/Host/doc.pdf", name: "doc.pdf", kind: .unsupported, size: 1, revision: "v1")
        let source = FileBrowserSource(id: "host", paneID: nil) { operation in
            switch operation {
            case .info: .info(entry)
            case let .download(path, offset, revision): .chunk(.init(path: path, revision: revision, offset: offset, data: Data([1])))
            default: throw FileBrowserError.message("Unexpected request")
            }
        }
        try await withDependencies {
            $0[FileBrowserDownloadClient.self] = .init(
                begin: { try await files.begin(name: $0, size: $1) },
                append: { try await files.append($1, to: $0) },
                finish: { try await files.finish($0) },
                discard: { await files.discard($0) },
                retain: { try await files.retain($0) },
                maintain: { await files.maintain() }
            )
        } operation: {
            let transfer = FileBrowserTransfer()
            let url = try await transfer.fileForOpening(path: entry.path, source: source)
            clock.withValue { $0.addTimeInterval(25 * 60 * 60) }
            await files.maintain()
            #expect(FileManager.default.fileExists(atPath: url.path))
            withExtendedLifetime(transfer) { }
        }
    }
}
