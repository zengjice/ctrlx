import CryptoKit
import CtrlxNetworking
import Dependencies
import Foundation
import Observation
import os

@MainActor @Observable
final class FileBrowserUpload {
    private(set) var isRunning = false
    private(set) var filename = ""
    private(set) var sentBytes = 0
    private(set) var totalBytes = 0
    private(set) var summary: String?
    @ObservationIgnored @Dependency(FileBrowserUploadReader.self) private var reader
    @ObservationIgnored private var generation = UUID()
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "FileUpload")

    func run(
        image: WorkspaceClipboardContent,
        directory: String,
        source: FileBrowserSource,
        onSaved: @MainActor () -> Void
    ) async {
        let token = UUID()
        generation = token
        isRunning = true
        summary = nil
        let name = "Clipboard-\(token.uuidString).\(image.kind == .jpeg ? "jpg" : "png")"
        filename = name
        sentBytes = 0
        totalBytes = image.data.count
        var committed = false
        defer {
            if generation == token {
                isRunning = false
            }
        }
        do {
            guard image.isValid, image.kind != .text else { throw FileBrowserError.message("Copy an image first.") }
            if let reason = source.unavailableReason ?? source.uploadUnavailableReason {
                throw FileBrowserError.message(reason)
            }
            try await acknowledge(.begin(id: token, directory: directory, name: name, size: image.data.count), offset: 0, source: source)
            var offset = 0
            while offset < image.data.count {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                let end = min(image.data.count, offset + FileBrowserLimits.chunkBytes)
                try await acknowledge(.append(id: token, offset: offset, data: image.data.subdata(in: offset..<end)), offset: end, source: source)
                offset = end
                if generation == token {
                    sentBytes = end
                }
            }
            let hash = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
            try await acknowledge(
                .finish(id: token, sha256: hash),
                offset: image.data.count,
                path: (directory as NSString).appendingPathComponent(name),
                source: source
            )
            committed = true
            if generation == token {
                summary = "Image saved."
                onSaved()
            }
        } catch {
            if generation == token {
                summary = Task.isCancelled ? "Upload cancelled." : error.localizedDescription
            }
        }
        if !committed {
            await Task {
                do { _ = try await source.request(.upload(.cancel(id: token))) }
                catch { Self.logger.debug("Clipboard upload cleanup failed: \(error.localizedDescription)") }
            }.value
        }
    }

    func run(urls: [URL], directory: String, source: FileBrowserSource,
             onSaved: @MainActor () -> Void) async {
        let token = UUID()
        generation = token
        isRunning = true
        summary = nil
        var completed = 0
        var errors: [String] = []
        defer {
            if generation == token {
                isRunning = false
                summary = "\(completed) file(s) saved." + (Task.isCancelled ? " Upload cancelled." : "")
                    + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
            }
        }
        if let reason = source.unavailableReason ?? source.uploadUnavailableReason {
            errors.append(reason)
            return
        }
        for url in urls {
            if Task.isCancelled || generation != token { return }
            filename = url.lastPathComponent
            sentBytes = 0
            totalBytes = 0
            var fileID: UUID?
            var committed = false
            do {
                let file = try await reader.open(url)
                fileID = file.id
                totalBytes = file.size
                try Task.checkCancellation()
                try await acknowledge(.begin(id: file.id, directory: directory, name: file.name, size: file.size), offset: 0, source: source)
                var offset = 0
                while offset < file.size {
                    try Task.checkCancellation()
                    let data = try await reader.read(file.id)
                    guard !data.isEmpty, data.count <= FileBrowserLimits.chunkBytes, data.count <= file.size - offset else {
                        throw FileBrowserError.message("Source returned an invalid file chunk.")
                    }
                    try await acknowledge(.append(id: file.id, offset: offset, data: data), offset: offset + data.count, source: source)
                    offset += data.count
                    if generation == token { sentBytes = offset }
                }
                let checksum = try await reader.finish(file.id)
                let path = (directory as NSString).appendingPathComponent(file.name)
                try await acknowledge(.finish(id: file.id, sha256: checksum), offset: file.size, path: path, source: source)
                committed = true
                completed += 1
                if generation == token { onSaved() }
            } catch {
                if !Task.isCancelled { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if let fileID {
                await reader.close(fileID)
                if !committed {
                    // Cancellation must still send cleanup. Host expiry/disconnect
                    // cleanup covers a lost cancel request or a lost begin reply.
                    await Task {
                        do { _ = try await source.request(.upload(.cancel(id: fileID))) }
                        catch { Self.logger.debug("Upload cleanup could not reach Host: \(error.localizedDescription)") }
                    }.value
                }
            }
        }
    }

    private func acknowledge(_ operation: FileBrowserUploadOperation, offset: Int, path: String? = nil,
                             source: FileBrowserSource) async throws {
        try Task.checkCancellation()
        guard case let .uploaded(actualOffset, actualPath) = try await source.request(.upload(operation)),
              actualOffset == offset, actualPath == path else {
            throw FileBrowserError.message("Host returned an invalid upload acknowledgement. Refresh before retrying.")
        }
    }
}
