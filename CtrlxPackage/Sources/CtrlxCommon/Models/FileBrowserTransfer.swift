import CtrlxNetworking
import Dependencies
import Foundation
import Observation

@MainActor @Observable
final class FileBrowserTransfer {
    private(set) var isPreparing = false
    private(set) var receivedBytes = 0
    private(set) var totalBytes = 0
    @ObservationIgnored @Dependency(FileBrowserDownloadClient.self) private var downloads
    @ObservationIgnored private var generation = UUID()

    func fileForOpening(path: String, source: FileBrowserSource,
                        maximumRemoteBytes: Int = FileBrowserLimits.maximumDownloadBytes) async throws -> URL {
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        isPreparing = true
        receivedBytes = 0
        totalBytes = 0
        defer { if generation == token { isPreparing = false } }
        if let reason = source.unavailableReason { throw FileBrowserError.message(reason) }
        if source.localFileURL == nil, let reason = source.downloadUnavailableReason { throw FileBrowserError.message(reason) }
        guard case let .info(info) = try await source.request(.info(path: path)) else {
            throw FileBrowserError.message("Missing file information.")
        }
        try Task.checkCancellation()
        if let localFileURL = source.localFileURL {
            let url = try await localFileURL(info)
            try Task.checkCancellation()
            return url
        }
        let limit = min(maximumRemoteBytes, FileBrowserLimits.maximumDownloadBytes)
        guard info.kind != .directory, info.size >= 0, info.size <= limit else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .binary)
            throw FileBrowserError.message("Only files up to \(size) can be downloaded here. Use Download and Open for larger preview files.")
        }
        totalBytes = info.size
        let url = try await downloads.begin(info.name, info.size)
        do {
            var offset = 0
            repeat {
                try Task.checkCancellation()
                guard case let .chunk(chunk) = try await source.request(.download(path: info.path, offset: offset, revision: info.revision)),
                      chunk.path == info.path, chunk.revision == info.revision, chunk.offset == offset,
                      (!chunk.data.isEmpty || info.size == 0), chunk.data.count <= FileBrowserLimits.chunkBytes, chunk.data.count <= info.size - offset else {
                    throw FileBrowserError.message("File changed or the Host returned an invalid download chunk.")
                }
                try Task.checkCancellation()
                try await downloads.append(url, chunk.data)
                offset += chunk.data.count
                if generation == token { receivedBytes = offset }
            } while offset < info.size
            guard case let .info(current) = try await source.request(.info(path: info.path)), current.revision == info.revision else {
                throw FileBrowserError.message("File changed during download. Try again.")
            }
            try Task.checkCancellation()
            try await downloads.finish(url)
            try Task.checkCancellation()
            return url
        } catch {
            await downloads.discard(url)
            throw error
        }
    }
}
