import CryptoKit
import CtrlxCommon
import CtrlxNetworking
import Darwin
import Foundation
import os

/// One instance per Viewer connection. Files stay private until an exclusive,
/// same-directory rename publishes the complete, checksum-verified contents.
actor HostFileUploads {
    static let local = HostFileUploads()
    private struct Upload {
        let directory: String
        let name: String
        let temporaryName: String
        let directoryFD: Int32
        let fileFD: Int32
        let size: Int
        var offset = 0
        var hash = SHA256()
        var activity = ContinuousClock.now
    }
    private var uploads: [UUID: Upload] = [:]
    private var closed = false
    private var expiryTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "FileUploads")

    func request(_ operation: FileBrowserUploadOperation) throws -> FileBrowserResponse {
        try Task.checkCancellation()
        guard !closed else { throw FileBrowserError.message("Upload connection closed.") }
        switch operation {
        case let .begin(id, directory, name, size):
            try begin(id: id, directory: directory, name: name, size: size)
            return .uploaded(offset: 0, path: nil)
        case let .cancel(id):
            discard(id)
            return .uploaded(offset: 0, path: nil)
        case let .append(id, offset, data):
            do {
                guard var upload = uploads[id], offset == upload.offset, !data.isEmpty,
                      data.count <= FileBrowserLimits.chunkBytes, data.count <= upload.size - offset else {
                    throw FileBrowserError.message("Invalid or expired upload chunk.")
                }
                try data.withUnsafeBytes { bytes in
                    var written = 0
                    while written < bytes.count {
                        try Task.checkCancellation()
                        let count = Darwin.write(upload.fileFD, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw posixError() }
                        written += count
                    }
                }
                upload.hash.update(data: data)
                upload.offset += data.count
                upload.activity = .now
                uploads[id] = upload
                return .uploaded(offset: upload.offset, path: nil)
            } catch { discard(id); throw error }
        case let .finish(id, checksum):
            defer { discard(id) }
            guard let upload = uploads[id], upload.offset == upload.size,
                  upload.hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else {
                throw FileBrowserError.message("Upload is incomplete or its checksum does not match.")
            }
            var current = stat(), opened = stat()
            guard stat(upload.directory, &current) == 0, fstat(upload.directoryFD, &opened) == 0,
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw FileBrowserError.message("Destination directory changed. Choose it again.")
            }
            guard fsync(upload.fileFD) == 0 else { throw posixError() }
            try Task.checkCancellation()
            guard renameatx_np(upload.directoryFD, upload.temporaryName, upload.directoryFD, upload.name, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw FileBrowserError.message("A file named \(upload.name) already exists. It was not replaced.") }
                throw posixError()
            }
            return .uploaded(offset: upload.size, path: (upload.directory as NSString).appendingPathComponent(upload.name))
        }
    }

    private func begin(id: UUID, directory: String, name: String, size: Int) throws {
        guard uploads[id] == nil, uploads.count < 4,
              SessionDirectoryName.isValid(name), size >= 0, size <= FileBrowserLimits.maximumUploadBytes,
              directory.utf8.count <= 4096,
              let path = SessionDirectoryPath.expanded(directory, hostHome: FileManager.default.homeDirectoryForCurrentUser.path) else {
            throw FileBrowserError.message("Invalid upload destination, size (maximum 1 GiB), or too many uploads.")
        }
        let directoryFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError() }
        var retained = false
        defer { if !retained { Darwin.close(directoryFD) } }
        var existing = stat()
        if fstatat(directoryFD, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            throw FileBrowserError.message("A file named \(name) already exists. It was not replaced.")
        }
        guard errno == ENOENT else { throw posixError() }
        var volume = statfs()
        guard fstatfs(directoryFD, &volume) == 0 else { throw posixError() }
        guard UInt64(volume.f_bavail) * UInt64(volume.f_bsize) >= UInt64(size) + 16 * 1_024 * 1_024 else {
            throw FileBrowserError.message("Not enough space on the Host for this file.")
        }
        let temporaryName = ".ctrlx-upload-\(UUID().uuidString).tmp"
        let fileFD = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileFD >= 0 else { throw posixError() }
        uploads[id] = Upload(directory: path, name: name, temporaryName: temporaryName,
                             directoryFD: directoryFD, fileFD: fileFD, size: size)
        retained = true
        if expiryTask == nil {
            expiryTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let active = await self?.expire(), active else { return }
                }
            }
        }
    }

    @discardableResult
    func expire(now: ContinuousClock.Instant = .now) -> Bool {
        for (id, upload) in uploads where now - upload.activity >= .seconds(60) { discard(id) }
        if uploads.isEmpty { expiryTask = nil }
        return !uploads.isEmpty
    }

    func shutdown() {
        closed = true
        expiryTask?.cancel()
        expiryTask = nil
        for id in Array(uploads.keys) { discard(id) }
    }

    private func discard(_ id: UUID) {
        guard let upload = uploads.removeValue(forKey: id) else { return }
        if Darwin.close(upload.fileFD) != 0 { Self.logger.error("Closing upload failed: \(errno)") }
        if unlinkat(upload.directoryFD, upload.temporaryName, 0) != 0, errno != ENOENT {
            Self.logger.error("Removing incomplete upload failed: \(errno)")
        }
        if Darwin.close(upload.directoryFD) != 0 { Self.logger.error("Closing upload directory failed: \(errno)") }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
