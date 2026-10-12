import CryptoKit
import CtrlxNetworking
import Dependencies
import Foundation
import os
import Testing
@testable import CtrlxCommon

@MainActor
struct FileBrowserUploadTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-reader-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func client(_ reader: UploadFileReader) -> FileBrowserUploadReader {
        .init(open: { try await reader.open($0) }, read: { try await reader.read($0) },
              finish: { try await reader.finish($0) }, close: { await reader.close($0) })
    }

    @Test func sequentialFilesHaveBoundedChunksFixedDestinationAndChecksums() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appendingPathComponent("中文 file.bin"), root.appendingPathComponent("empty")]
        let data = Data(repeating: 15, count: FileBrowserLimits.chunkBytes + 7)
        try data.write(to: urls[0]); try Data().write(to: urls[1])
        var content = Data(), completed = 0, currentName = ""
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .upload(request) = operation else { throw FileBrowserError.message("Expected upload") }
            switch request {
            case let .begin(_, directory, name, _):
                #expect(directory == "/Host/target")
                content = Data(); currentName = name
                return .uploaded(offset: 0, path: nil)
            case let .append(_, offset, bytes):
                #expect(bytes.count <= FileBrowserLimits.chunkBytes)
                #expect(offset == content.count)
                content.append(bytes)
                return .uploaded(offset: content.count, path: nil)
            case let .finish(_, hash):
                #expect(hash == SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
                return .uploaded(offset: content.count, path: "/Host/target/\(currentName)")
            case .cancel: Issue.record("Successful uploads should not cancel"); return .uploaded(offset: 0, path: nil)
            }
        }
        await withDependencies { $0[FileBrowserUploadReader.self] = client(UploadFileReader()) } operation: {
            let upload = FileBrowserUpload()
            await upload.run(urls: urls, directory: "/Host/target", source: source) { completed += 1 }
            #expect(completed == 2)
            #expect(upload.summary == "2 file(s) saved.")
            #expect(!upload.isRunning)
        }
        #expect(try Data(contentsOf: urls[0]) == data, "Import copies, never moves")
    }

    @Test func failedFileIsCancelledAndNextFileContinues() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = [root.appendingPathComponent("duplicate"), root.appendingPathComponent("good")]
        for url in urls { try Data().write(to: url) }
        var cancelled = 0, saved = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .upload(request) = operation else { throw FileBrowserError.message("Expected upload") }
            switch request {
            case let .begin(_, _, name, _):
                if name == "duplicate" { throw FileBrowserError.message("Already exists") }
                return .uploaded(offset: 0, path: nil)
            case .finish: return .uploaded(offset: 0, path: "/Host/good")
            case .cancel: cancelled += 1; return .uploaded(offset: 0, path: nil)
            case .append: throw FileBrowserError.message("Unexpected chunk")
            }
        }
        await withDependencies { $0[FileBrowserUploadReader.self] = client(UploadFileReader()) } operation: {
            let upload = FileBrowserUpload()
            await upload.run(urls: urls, directory: "/Host", source: source) { saved += 1 }
            #expect(cancelled == 1 && saved == 1)
            #expect(upload.summary?.contains("duplicate: Already exists") == true)
        }
    }

    @Test func oldHostIsRejectedBeforeReadingOrSending() async {
        var calls = 0
        let source = FileBrowserSource(id: "legacy", paneID: nil, uploadUnavailableReason: "Update Host") { _ in
            calls += 1; return .uploaded(offset: 0, path: nil)
        }
        let upload = FileBrowserUpload()
        await upload.run(urls: [URL(fileURLWithPath: "/unreadable")], directory: "/Host", source: source) { Issue.record("Unexpected save") }
        #expect(calls == 0)
        #expect(upload.summary?.contains("Update Host") == true)
    }

    @Test func readerRejectsFoldersAndLinks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = UploadFileReader()
        await #expect(throws: (any Error).self) { try await reader.open(root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
        try Data([1, 2]).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: (any Error).self) { try await reader.open(link) }
    }

    @Test func snapshotSurvivesLaterSavesAndCloses() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = UploadFileReader()
        let file = root.appendingPathComponent("file")
        let original = Data(repeating: 42, count: FileBrowserLimits.chunkBytes + 7)
        try original.write(to: file)
        let opened = try await reader.open(file)
        // A new coordinated save must not wait for the network upload to finish.
        try await Task.detached {
            var coordinationError: NSError?
            var result: Result<Void, any Error>?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
                result = Result { try Data([1]).write(to: url) }
            }
            if let coordinationError { throw coordinationError }
            try #require(result).get()
        }.value
        var content = Data()
        while content.count < opened.size {
            let chunk = try await reader.read(opened.id)
            try #require(!chunk.isEmpty)
            #expect(chunk.count <= FileBrowserLimits.chunkBytes)
            content.append(chunk)
        }
        #expect(content == original)
        #expect(try await reader.finish(opened.id) == SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        await reader.close(opened.id)
        await #expect(throws: (any Error).self) { try await reader.read(opened.id) }
        #expect(try Data(contentsOf: file) == Data([1]))
    }

    @Test(arguments: [false, true])
    func readerWaitsForCoordinatedSaveOrCancels(cancel: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("saving.txt")
        try Data("before".utf8).write(to: file)
        let gate = UploadSaveGate()
        defer { gate.release() }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let writer = Task.detached {
            defer { signal.finish() }
            var coordinationError: NSError?
            var result: Result<Void, any Error>?
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
                result = Result {
                    try Data("partial".utf8).write(to: url)
                    signal.yield()
                    try gate.wait()
                    try Data("complete saved contents".utf8).write(to: url)
                }
            }
            if let coordinationError { throw coordinationError }
            try #require(result).get()
        }
        for await _ in started { break }
        let reader = UploadFileReader()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let (reading, readingSignal) = AsyncStream<Void>.makeStream()
        let pending = Task.detached {
            readingSignal.yield(); readingSignal.finish()
            defer { finished.withLock { $0 = true } }
            return try await reader.open(file)
        }
        for await _ in reading { break }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!finished.withLock { $0 }, "Reader must not accept stable partial bytes while a save holds coordination")
        if cancel {
            pending.cancel()
            try await Task.sleep(for: .milliseconds(200))
            #expect(finished.withLock { $0 }, "Cancellation must stop waiting without requiring the writer to finish")
        }
        gate.release()
        try await writer.value
        do {
            let opened = try await pending.value
            if cancel { Issue.record("Cancelled open returned a snapshot") }
            #expect(try await reader.read(opened.id) == Data("complete saved contents".utf8))
            _ = try await reader.finish(opened.id)
            await reader.close(opened.id)
        } catch {
            if !cancel { throw error }
            #expect(error is CancellationError)
        }
    }

    @Test func cancellingWhileHostAcknowledgesStopsBatchAndSendsCleanup() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("file")
        try Data([1]).write(to: url)
        let (began, signal) = AsyncStream<Void>.makeStream()
        var cancelled = 0, begins = 0
        let source = FileBrowserSource(id: "remote", paneID: nil) { operation in
            guard case let .upload(request) = operation else { throw FileBrowserError.message("Expected upload") }
            switch request {
            case .begin:
                begins += 1
                signal.yield(); signal.finish()
                try await Task.sleep(for: .seconds(30))
                return .uploaded(offset: 0, path: nil)
            case .cancel:
                #expect(!Task.isCancelled, "Cleanup needs an uncancelled task")
                cancelled += 1
                return .uploaded(offset: 0, path: nil)
            default: Issue.record("Cancelled upload continued"); throw CancellationError()
            }
        }
        await withDependencies { $0[FileBrowserUploadReader.self] = client(UploadFileReader()) } operation: {
            let upload = FileBrowserUpload()
            let task = Task { await upload.run(urls: [url, url], directory: "/Host", source: source) { Issue.record("Unexpected save") } }
            for await _ in began { break }
            task.cancel()
            await task.value
            #expect(begins == 1 && cancelled == 1)
            #expect(!upload.isRunning)
            #expect(upload.summary?.contains("cancelled") == true)
        }
    }
}

/// The synchronous accessor deliberately holds a coordinated save between writes.
private final class UploadSaveGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func wait() throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while !released {
            guard condition.wait(until: deadline) else {
                throw FileBrowserError.message("Timed out waiting for test save release.")
            }
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
