import ConcurrencyExtras
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
struct FileBrowserOfficeDocumentTests {
    @Test(arguments: ["doc", "docx", "xls", "xlsx", "ppt", "pptx"])
    func recognizesOnlyOfficeDocumentExtensions(fileExtension: String) async {
        let path = "/Host/中文 文档.\(fileExtension.uppercased())"
        #expect(FileBrowserOfficeDocument.supports(path: path))
        #expect(!FileBrowserOfficeDocument.supports(path: path + ".pdf"))
        let tab = FileBrowserTab()
        tab.selectedFile = path
        var requests = 0
        let source = FileBrowserSource(id: "legacy-host", paneID: nil) { _ in
            requests += 1
            throw FileBrowserError.message("Office must not use bounded text reads")
        }
        await tab.loadPreview(source: source)
        #expect(requests == 0)
        #expect(tab.previewData == nil)
        #expect(tab.previewError == nil)
        #expect(!tab.isPreviewLoading)
    }

    @Test(arguments: ["md", "txt", "pdf", "png", "mp4", "docm", "xlsm", "pptm", "zip", ""])
    func leavesOtherFormatsOnTheirExistingPath(fileExtension: String) {
        #expect(!FileBrowserOfficeDocument.supports(path: "/Host/file.\(fileExtension)"))
    }

    @Test(arguments: [FileBrowserKind.text, .unsupported], [0, FileBrowserLimits.chunkBytes + 7])
    func officeCopiesUseTheExistingDownloadProtocol(kind: FileBrowserKind, size: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-office-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileBrowserDownloads(root: root)
        let data = Data(repeating: 0xFF, count: size)
        let info = FileBrowserEntry(path: "/Host/中文 文档.docx", name: "中文 文档.docx", kind: kind, size: size, revision: "1")
        var offsets: [Int] = []
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation { return .info(info) }
            guard case let .download(path, offset, revision) = operation else {
                throw FileBrowserError.message("Office must not use text or image reads")
            }
            #expect(path == info.path && revision == info.revision)
            offsets.append(offset)
            return .chunk(.init(path: path, revision: revision, offset: offset,
                data: data.subdata(in: offset..<min(offset + FileBrowserLimits.chunkBytes, size))))
        }
        try await withDependencies {
            $0[FileBrowserDownloadClient.self] = .init(
                begin: { try await files.begin(name: $0, size: $1) },
                append: { try await files.append($1, to: $0) },
                finish: { try await files.finish($0) },
                discard: { await files.discard($0) })
        } operation: {
            let transfer = FileBrowserTransfer()
            let url = try await transfer.fileForOpening(path: info.path, source: source,
                maximumRemoteBytes: FileBrowserOfficeDocument.maximumPreviewBytes)
            #expect(url.path != info.path)
            #expect(url.lastPathComponent == info.name)
            #expect(try Data(contentsOf: url) == data)
            #expect(transfer.receivedBytes == size)
            #expect(offsets == (size == 0 ? [0] : [0, FileBrowserLimits.chunkBytes]))
        }
    }

    @Test(arguments: [FileBrowserOfficeDocument.maximumPreviewBytes, FileBrowserOfficeDocument.maximumPreviewBytes + 1])
    func officeLimitIsEnforcedBeforeCreatingRemoteCache(size: Int) async {
        let info = FileBrowserEntry(path: "/Host/large.xlsx", name: "large.xlsx", kind: .text, size: size, revision: "1")
        let source = FileBrowserSource(id: "remote", paneID: nil) { _ in .info(info) }
        let attempts = LockIsolated(0)
        await withDependencies {
            $0[FileBrowserDownloadClient.self].begin = { _, _ in
                attempts.withValue { $0 += 1 }
                throw FileBrowserError.message("Reached download")
            }
        } operation: {
            await #expect(throws: FileBrowserError.self) {
                try await FileBrowserTransfer().fileForOpening(path: info.path, source: source,
                    maximumRemoteBytes: FileBrowserOfficeDocument.maximumPreviewBytes)
            }
        }
        #expect(attempts.value == (size <= FileBrowserOfficeDocument.maximumPreviewBytes ? 1 : 0))
        if size > FileBrowserOfficeDocument.maximumPreviewBytes {
            await withDependencies {
                $0[FileBrowserDownloadClient.self].begin = { _, _ in
                    attempts.withValue { $0 += 1 }
                    throw FileBrowserError.message("Reached explicit download")
                }
            } operation: {
                await #expect(throws: FileBrowserError.self) {
                    try await FileBrowserTransfer().fileForOpening(path: info.path, source: source)
                }
            }
            #expect(attempts.value == 1, "The preview cap must not limit explicit Download and Open")
        }
    }

    @Test func localOfficeURLBypassesRemoteLimitAndLegacyHostIsRejected() async throws {
        let info = FileBrowserEntry(path: "/Host/large.pptx", name: "large.pptx", kind: .text,
            size: FileBrowserOfficeDocument.maximumPreviewBytes + 1, revision: "1")
        let local = FileBrowserSource(id: "local", paneID: nil, localFileURL: { _ in URL(fileURLWithPath: info.path) }) { operation in
            guard case .info = operation else { throw FileBrowserError.message("Local Office must not download") }
            return .info(info)
        }
        let transfer = FileBrowserTransfer()
        #expect(try await transfer.fileForOpening(path: info.path, source: local,
            maximumRemoteBytes: FileBrowserOfficeDocument.maximumPreviewBytes).path == info.path)
        var requests = 0
        let legacy = FileBrowserSource(id: "old-host", paneID: nil, downloadUnavailableReason: "Update the Host Mac") { _ in
            requests += 1
            return .info(info)
        }
        await #expect(throws: FileBrowserError.self) {
            try await transfer.fileForOpening(path: info.path, source: legacy,
                maximumRemoteBytes: FileBrowserOfficeDocument.maximumPreviewBytes)
        }
        #expect(requests == 0)
    }

    @Test func cancellingAnOfficeTransferRemovesThePartialCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-office-cancel-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileBrowserDownloads(root: root)
        let info = FileBrowserEntry(path: "/Host/file.docx", name: "file.docx", kind: .text,
            size: FileBrowserLimits.chunkBytes + 1, revision: "1")
        let (started, notify) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { notify.finish(); release.finish() }
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            if case .info = operation { return .info(info) }
            guard case let .download(path, offset, revision) = operation else {
                throw FileBrowserError.message("Unexpected operation")
            }
            if offset > 0 {
                notify.yield()
                for await _ in gate { break }
            }
            return .chunk(.init(path: path, revision: revision, offset: offset,
                data: Data(repeating: 1, count: min(FileBrowserLimits.chunkBytes, info.size - offset))))
        }
        try await withDependencies {
            $0[FileBrowserDownloadClient.self] = .init(
                begin: { try await files.begin(name: $0, size: $1) },
                append: { try await files.append($1, to: $0) },
                finish: { try await files.finish($0) },
                discard: { await files.discard($0) })
        } operation: {
            let transfer = FileBrowserTransfer()
            let task = Task {
                try await transfer.fileForOpening(path: info.path, source: source,
                    maximumRemoteBytes: FileBrowserOfficeDocument.maximumPreviewBytes)
            }
            for await _ in started { break }
            #expect(transfer.receivedBytes == FileBrowserLimits.chunkBytes)
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(!transfer.isPreparing)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(remaining.isEmpty)
        }
    }
}
