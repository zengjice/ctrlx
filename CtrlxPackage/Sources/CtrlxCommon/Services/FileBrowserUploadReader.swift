import CryptoKit
import CtrlxNetworking
import Darwin
import Dependencies
import DependenciesMacros
import Foundation
import os

struct FileBrowserUploadFile: Sendable {
    let id: UUID
    let name: String
    let size: Int
}

@DependencyClient
struct FileBrowserUploadReader: Sendable {
    var open: @Sendable (URL) async throws -> FileBrowserUploadFile
    var read: @Sendable (UUID) async throws -> Data
    var finish: @Sendable (UUID) async throws -> String
    var close: @Sendable (UUID) async -> Void
}

extension FileBrowserUploadReader: DependencyKey {
    static let liveValue: Self = {
        let reader = UploadFileReader()
        return Self(open: { try await reader.open($0) }, read: { try await reader.read($0) },
                    finish: { try await reader.finish($0) }, close: { await reader.close($0) })
    }()
}

/// Upload a coordinated snapshot, not a live file that another app may be saving.
/// Keep only its descriptor during transfer; never load the entire file in memory.
actor UploadFileReader {
    private struct File {
        let descriptor: Int32
        let original: stat
        var offset = 0
        var hash = SHA256()
    }
    private var files: [UUID: File] = [:]
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "UploadReader")

    func open(_ url: URL) async throws -> FileBrowserUploadFile {
        try Task.checkCancellation()
        guard url.isFileURL else { throw FileBrowserError.message("Choose a local file.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // forUploading also archives directories. Reject those (and oversized
        // files) before asking the system to create a snapshot.
        var source = stat()
        guard lstat(url.path, &source) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try validate(source, name: url.lastPathComponent)

        let coordination = UploadSnapshotCoordination()
        let descriptor = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try coordination.open(url)
        } onCancel: {
            coordination.cancel()
        }
        var retained = false
        defer { if !retained { Darwin.close(descriptor) } }
        try Task.checkCancellation()
        // The coordinator unlinks the snapshot after its accessor returns.
        // Capture metadata afterwards, including the unlink's ctime change.
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try validate(info, name: url.lastPathComponent)
        let id = UUID()
        files[id] = File(descriptor: descriptor, original: info)
        retained = true
        return .init(id: id, name: url.lastPathComponent, size: Int(info.st_size))
    }

    func read(_ id: UUID) throws -> Data {
        try Task.checkCancellation()
        guard var file = files[id] else { throw FileBrowserError.message("Source file is closed.") }
        try check(file)
        let remaining = Int(file.original.st_size) - file.offset
        var data = Data(count: min(FileBrowserLimits.chunkBytes, remaining))
        let count = data.withUnsafeMutableBytes { bytes in
            Darwin.read(file.descriptor, bytes.baseAddress, bytes.count)
        }
        guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard count > 0 || remaining == 0 else { throw FileBrowserError.message("Source file changed during upload.") }
        data.count = count
        file.hash.update(data: data)
        file.offset += count
        files[id] = file
        return data
    }

    func finish(_ id: UUID) throws -> String {
        try Task.checkCancellation()
        guard let file = files[id], file.offset == file.original.st_size else {
            throw FileBrowserError.message("Source file was not completely read.")
        }
        try check(file)
        return file.hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func close(_ id: UUID) {
        guard let file = files.removeValue(forKey: id) else { return }
        if Darwin.close(file.descriptor) != 0 { Self.logger.error("Closing source file failed: \(errno)") }
    }

    private func validate(_ info: stat, name: String) throws {
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= FileBrowserLimits.maximumUploadBytes,
              SessionDirectoryName.isValid(name) else {
            throw FileBrowserError.message("Choose a regular file up to 1 GiB, not a folder or symbolic link.")
        }
    }

    private func check(_ file: File) throws {
        var current = stat()
        guard fstat(file.descriptor, &current) == 0,
              current.st_size == file.original.st_size,
              current.st_mtimespec.tv_sec == file.original.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == file.original.st_mtimespec.tv_nsec,
              current.st_ctimespec.tv_sec == file.original.st_ctimespec.tv_sec,
              current.st_ctimespec.tv_nsec == file.original.st_ctimespec.tv_nsec else {
            throw FileBrowserError.message("Source file changed during upload. Choose it again.")
        }
    }
}

/// Used for one synchronous coordination only. The sole cross-thread operation
/// is cancel(), which NSFileCoordinator explicitly permits from any thread.
private final class UploadSnapshotCoordination: @unchecked Sendable {
    private let coordinator = NSFileCoordinator()

    func open(_ url: URL) throws -> Int32 {
        var coordinationError: NSError?
        var result: Result<Int32, any Error>?
        coordinator.coordinate(readingItemAt: url, options: .forUploading, error: &coordinationError) { snapshot in
            result = Result {
                try Task.checkCancellation()
                // Open inside the accessor: the URL is removed when it returns,
                // but the descriptor keeps the snapshot alive until close().
                let descriptor = Darwin.open(snapshot.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                return descriptor
            }
        }
        if let coordinationError {
            if case let .success(descriptor) = result { Darwin.close(descriptor) }
            try Task.checkCancellation()
            throw coordinationError
        }
        guard let result else { throw FileBrowserError.message("Could not prepare the file for upload.") }
        return try result.get()
    }

    func cancel() { coordinator.cancel() }
}
