import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct FileBrowserTransferTests {
    private func client(_ files: FileBrowserDownloads) -> FileBrowserDownloadClient {
        .init(begin: { try await files.begin(name: $0, size: $1) },
              append: { try await files.append($1, to: $0) },
              finish: { try await files.finish($0) },
              discard: { await files.discard($0) })
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-transfer-test-\(UUID())", isDirectory: true)
    }

    @Test(arguments: [0, FileBrowserLimits.chunkBytes + 7])
    func explicitDownloadWritesVerifiedChunksToDisk(size: Int) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 7, count: size)
        let info = FileBrowserEntry(path: "/Host/movie.mp4", name: "movie.mp4", kind: .unsupported, size: size, revision: "1")
        var offsets: [Int] = []
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation { return .info(info) }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Expected export, not preview") }
            #expect(path == info.path && revision == info.revision)
            offsets.append(offset)
            return .chunk(.init(path: path, revision: revision, offset: offset,
                               data: data.subdata(in: offset..<min(offset + FileBrowserLimits.chunkBytes, size))))
        }
        try await withDependencies { $0[FileBrowserDownloadClient.self] = client(FileBrowserDownloads(root: root)) } operation: {
            let transfer = FileBrowserTransfer()
            let url = try await transfer.fileForOpening(path: info.path, source: source)
            #expect(url.path.hasPrefix(root.path + "/"))
            #expect(url.path != info.path)
            #expect(url.lastPathComponent == info.name)
            #expect(try Data(contentsOf: url) == data)
            #expect(transfer.receivedBytes == size)
            #expect(!transfer.isPreparing)
            #expect(offsets == (size == 0 ? [0] : [0, FileBrowserLimits.chunkBytes]))
        }
    }

    @Test(arguments: ["revision", "offset", "oversized", "empty", "final-revision", "cancel", "disconnect"])
    func failedOrCancelledTransfersLeaveNoPartialCopy(failure: String) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let info = FileBrowserEntry(path: "/Host/movie.mp4", name: "movie.mp4", kind: .unsupported, size: FileBrowserLimits.chunkBytes + 1, revision: "1")
        var metadataReads = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation {
                metadataReads += 1
                return .info(.init(path: info.path, name: info.name, kind: info.kind, size: info.size,
                                   revision: metadataReads > 1 && failure == "final-revision" ? "changed" : "1"))
            }
            guard case let .download(path, offset, revision) = operation else { throw FileBrowserError.message("Unexpected operation") }
            if offset > 0 {
                if failure == "cancel" { throw CancellationError() }
                if failure == "disconnect" { throw FileBrowserError.message("Host offline") }
            }
            return .chunk(.init(path: path, revision: failure == "revision" ? "changed" : revision,
                               offset: failure == "offset" ? offset + 1 : offset,
                               data: Data(repeating: 1, count: failure == "empty" ? 0 : failure == "oversized" ? FileBrowserLimits.chunkBytes + 1 : min(FileBrowserLimits.chunkBytes, info.size - offset))))
        }
        try await withDependencies { $0[FileBrowserDownloadClient.self] = client(FileBrowserDownloads(root: root)) } operation: {
            let transfer = FileBrowserTransfer()
            await #expect(throws: (any Error).self) { try await transfer.fileForOpening(path: info.path, source: source) }
            #expect(!transfer.isPreparing)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(remaining.isEmpty)
        }
    }

    @Test func nativeOpenBypassesDownloadAndLegacyHostFailsBeforeAnyRequest() async throws {
        let info = FileBrowserEntry(path: "/Host/movie.mp4", name: "movie.mp4", kind: .unsupported,
                                   size: FileBrowserLimits.maximumDownloadBytes + 1, revision: "1")
        let local = FileBrowserSource(id: "local", paneID: nil, localFileURL: { _ in URL(fileURLWithPath: info.path) }) { operation in
            guard case .info = operation else { throw FileBrowserError.message("No download expected") }
            return .info(info)
        }
        let transfer = FileBrowserTransfer()
        #expect(try await transfer.fileForOpening(path: info.path, source: local).path == info.path)
        var calls = 0
        let remote = FileBrowserSource(id: "old-host", paneID: nil, downloadUnavailableReason: "Update the Host Mac") { _ in
            calls += 1
            return .info(info)
        }
        await #expect(throws: FileBrowserError.self) { try await transfer.fileForOpening(path: info.path, source: remote) }
        #expect(calls == 0)
        #expect(!transfer.isPreparing)
    }

    @Test func emptySpecialFileStillRequiresAValidatedHostRead() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation {
                return .info(.init(path: "/Host/pipe", name: "pipe", kind: .unsupported, size: 0, revision: "1"))
            }
            throw FileBrowserError.message("Only regular files can be downloaded")
        }
        try await withDependencies { $0[FileBrowserDownloadClient.self] = client(FileBrowserDownloads(root: root)) } operation: {
            await #expect(throws: FileBrowserError.self) {
                try await FileBrowserTransfer().fileForOpening(path: "/Host/pipe", source: source)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(remaining.isEmpty)
        }
    }

    @Test func downloadStorageRejectsUnsafeNamesAndExpiresOnlyInactiveCopies() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileBrowserDownloads(root: root)
        for name in ["", ".", "..", "../escape.mp4", "/absolute.mp4"] {
            await #expect(throws: FileBrowserError.self) { try await files.begin(name: name, size: 0) }
        }
        let first = try await files.begin(name: "中文 视频.mp4", size: 3)
        try await files.append(Data([1, 2, 3]), to: first)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)], ofItemAtPath: first.deletingLastPathComponent().path)
        let second = try await files.begin(name: "second.mp4", size: 0)
        #expect(FileManager.default.fileExists(atPath: first.path), "Active downloads cannot be cleaned")
        try await files.finish(first)
        try await files.finish(second)
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]), "Finishing must not delete a file still needed by another app")
        let third = try await files.begin(name: "third.mp4", size: 0)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        await files.discard(third)
        #expect(!FileManager.default.fileExists(atPath: third.path))
    }
}
