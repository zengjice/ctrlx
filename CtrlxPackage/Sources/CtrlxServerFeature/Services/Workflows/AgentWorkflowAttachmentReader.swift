import CryptoKit
import CtrlxNetworking
import Darwin
import Foundation
import ImageIO

struct AgentWorkflowAttachmentFile: Equatable, Sendable {
    let attachment: AgentWorkflowAttachment
    let url: URL
}

/// Hashing large media must not occupy the workflow ledger or the UI actor.
actor AgentWorkflowAttachmentReader {
    func validate(_ files: [AgentWorkflowAttachmentFile]) throws {
        for file in files {
            try validate(file)
        }
    }

    private func validate(_ file: AgentWorkflowAttachmentFile) throws {
        try Task.checkCancellation()
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw AgentWorkflowError("Cannot open \(file.attachment.name). Import it again.") }
        defer { Darwin.close(fd) }
        var initial = stat()
        guard
            fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size == file.attachment.byteCount else {
            throw AgentWorkflowError("\(file.attachment.name) changed after import.")
        }
        let maximumBytes: Int64
        switch file.attachment.mediaType {
        case "image/png",
             "image/jpeg": maximumBytes = 20 * 1_024 * 1_024
        case "text/plain",
             "text/markdown": maximumBytes = 2 * 1_024 * 1_024
        default: throw AgentWorkflowError("Convert \(file.attachment.name) to a supported representation before running the workflow.")
        }
        guard initial.st_size > 0, initial.st_size <= maximumBytes else {
            throw AgentWorkflowError("\(file.attachment.name) exceeds the workflow reading limit (images 20 MiB; UTF-8 text 2 MiB). Convert or split it before starting.")
        }
        var hash = SHA256(), total: Int64 = 0
        var contents = Data()
        var bytes = [UInt8](repeating: 0, count: 128 * 1_024)
        while total < initial.st_size {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &bytes, min(bytes.count, Int(initial.st_size - total)))
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { throw AgentWorkflowError("Could not verify all of \(file.attachment.name).") }
            hash.update(data: bytes.prefix(count))
            contents.append(contentsOf: bytes.prefix(count))
            total += Int64(count)
        }
        var final = stat()
        guard
            fstat(fd, &final) == 0,
            initial.st_size == final.st_size,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
            initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
            initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec,
            hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.attachment.sha256 else {
            throw AgentWorkflowError("\(file.attachment.name) no longer matches its imported contents.")
        }
        switch file.attachment.mediaType {
        case "image/png",
             "image/jpeg":
            guard
                let source = CGImageSourceCreateWithData(contents as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?,
                type == (file.attachment.mediaType == "image/png" ? "public.png" : "public.jpeg") else {
                throw AgentWorkflowError("\(file.attachment.name) is not a valid \(file.attachment.mediaType) image.")
            }
        case "text/plain",
             "text/markdown":
            // Bound decoding as well as terminal input; oversized text remains
            // stored but cannot silently become an incomplete Agent input.
            guard let text = String(data: contents, encoding: .utf8), !text.isEmpty else {
                throw AgentWorkflowError("\(file.attachment.name) must be nonempty UTF-8 text up to 2 MiB.")
            }
        default:
            throw AgentWorkflowError("Convert \(file.attachment.name) to a supported representation before running the workflow.")
        }
        var path = stat()
        guard lstat(file.url.path, &path) == 0, path.st_dev == initial.st_dev, path.st_ino == initial.st_ino else {
            throw AgentWorkflowError("\(file.attachment.name) was replaced while being verified.")
        }
    }
}
