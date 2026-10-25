import CryptoKit
import Foundation

enum WorkflowArtifactUpload {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }

    static func send(
        file: URL, invocationID: UUID,
        request: (JSONRPCRequest) throws -> JSONRPCResponse
    ) throws -> JSONRPCResponse {
        let mediaType = try mediaType(for: file)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(message: "Cannot open the artifact. Choose a readable regular file, not a symbolic link.") }
        defer { close(fd) }
        var original = stat()
        guard
            fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
            original.st_size > 0, original.st_size <= 1_024 * 1_024 * 1_024 else {
            throw Failure(message: "Choose a nonempty regular file up to 1 GiB.")
        }
        let size = Int(original.st_size)
        let uploadID = UUID()
        func call(_ action: String, fields: [String: JSONValue] = [:], offset: Int) throws -> JSONRPCResponse {
            let params = fields.merging([
                "invocationId": .string(invocationID.uuidString), "uploadId": .string(uploadID.uuidString), "action": .string(action),
            ]) { _, value in value }
            let command = JSONRPCRequest(id: UUID().uuidString, method: "workflow.artifact", params: params)
            let response = try request(command)
            guard response.id == command.id else { throw Failure(message: "The Host returned a receipt for another request.") }
            guard response.ok else { throw Failure(message: response.error?.message ?? "The Host rejected the artifact upload.") }
            guard
                response.result?["uploadId"] == .string(uploadID.uuidString),
                response.result?["invocationId"] == .string(invocationID.uuidString),
                response.result?["offset"] == .int(offset) else {
                throw Failure(message: "The Host returned an inconsistent artifact receipt.")
            }
            return response
        }
        var finishSent = false
        do {
            _ = try call("begin", fields: ["name": .string(file.lastPathComponent), "mediaType": .string(mediaType), "size": .int(size)], offset: 0)
            var hash = SHA256()
            var offset = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while offset < size {
                try verifySnapshot(fd, file: file, original: original)
                let count = Darwin.read(fd, &buffer, min(buffer.count, size - offset))
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw Failure(message: "The artifact could not be read completely.") }
                let chunk = Data(buffer.prefix(count))
                hash.update(data: chunk)
                try verifySnapshot(fd, file: file, original: original)
                _ = try call("append", fields: ["offset": .int(offset), "data": .string(chunk.base64EncodedString())], offset: offset + count)
                offset += count
            }
            try verifySnapshot(fd, file: file, original: original)
            let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
            finishSent = true
            let response = try call("finish", fields: ["sha256": .string(checksum)], offset: size)
            guard
                case let .object(artifact) = response.result?["artifact"],
                artifact["id"] == .string(uploadID.uuidString), artifact["size"] == .int(size),
                artifact["name"] == .string(file.lastPathComponent), artifact["mediaType"] == .string(mediaType),
                artifact["sha256"] == .string(checksum) else {
                throw Failure(message: "The Host returned different artifact metadata.")
            }
            return response
        } catch {
            var message = error.localizedDescription
            do { _ = try call("cancel", offset: 0) }
            catch { message += " Cleanup was not confirmed: \(error.localizedDescription)" }
            if finishSent {
                message += " Publication may have completed; check the workflow record before sharing again. No upload was retried."
            }
            throw Failure(message: message)
        }
    }

    private static func verifySnapshot(_ fd: Int32, file: URL, original: stat) throws {
        var current = stat()
        var path = stat()
        guard
            fstat(fd, &current) == 0, lstat(file.path, &path) == 0,
            current.st_size == original.st_size,
            current.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
            current.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
            current.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
            current.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec,
            path.st_mode & S_IFMT == S_IFREG, path.st_dev == original.st_dev, path.st_ino == original.st_ino else {
            throw Failure(message: "The artifact changed during upload. Save it, then share a fresh snapshot.")
        }
    }

    private static func mediaType(for file: URL) throws -> String {
        switch file.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg",
             "jpeg": "image/jpeg"
        case "txt": "text/plain"
        case "md",
             "markdown": "text/markdown"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        default: throw Failure(message: "Choose PNG, JPEG, UTF-8 text/Markdown, WAV, MP3, M4A, MP4 or MOV. The receiving Agent must support the media or use an explicit conversion.")
        }
    }
}
