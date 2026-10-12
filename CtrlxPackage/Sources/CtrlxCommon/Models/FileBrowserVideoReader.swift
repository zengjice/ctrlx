import CtrlxNetworking
import Foundation

enum FileBrowserVideo {
    static let cacheBytes = 8 * 1_024 * 1_024

    static func supports(path: String) -> Bool {
        ["mp4", "mov"].contains((path as NSString).pathExtension.lowercased())
    }
}

/// AVFoundation can ask for the file tail before the first frame, or request
/// everything to EOF. Clip each reply, not the whole request, to a wire chunk.
struct FileBrowserVideoRange {
    let start: Int
    let end: Int

    init(offset: Int64, length: Int, toEnd: Bool, size: Int) throws {
        guard offset >= 0, offset <= size, length >= 0 else {
            throw FileBrowserError.message("Invalid video byte range.")
        }
        start = Int(offset)
        end = toEnd ? size : start + min(length, size - start)
    }
}

/// One resource-loader worker owns this bounded memory cache. File reads still
/// run on the existing Host I/O actor / encrypted connection, never on local disk.
@MainActor
final class FileBrowserVideoReader {
    let info: FileBrowserEntry
    private let source: FileBrowserSource
    private let capacity: Int
    private var chunks: [Int: Data] = [:]
    private var recent: [Int] = []
    private(set) var cachedBytes = 0

    init(info: FileBrowserEntry, source: FileBrowserSource, cacheBytes: Int = FileBrowserVideo.cacheBytes) throws {
        guard info.kind != .directory, info.size > 0, info.size <= FileBrowserLimits.maximumDownloadBytes,
              FileBrowserVideo.supports(path: info.path) else {
            throw FileBrowserError.message("Stream previews support MP4/MOV files up to 1 GiB. Use Download and Open for other formats.")
        }
        self.info = info
        self.source = source
        capacity = max(1, cacheBytes / FileBrowserLimits.chunkBytes)
    }

    func read(offset: Int, length: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= info.size, length >= 0 else {
            throw FileBrowserError.message("Invalid video byte range.")
        }
        guard offset < info.size, length > 0 else { return Data() }
        let block = offset / FileBrowserLimits.chunkBytes * FileBrowserLimits.chunkBytes
        let data: Data
        if let cached = chunks[block] {
            data = cached
        } else {
            guard case let .chunk(chunk) = try await source.request(.download(path: info.path, offset: block, revision: info.revision)),
                  chunk.path == info.path, chunk.revision == info.revision, chunk.offset == block,
                  chunk.data.count == min(FileBrowserLimits.chunkBytes, info.size - block) else {
                throw FileBrowserError.message("Video changed or the Host returned an invalid chunk. Refresh its preview.")
            }
            try Task.checkCancellation()
            data = chunk.data
            if chunks.count == capacity, let oldest = recent.first, let removed = chunks.removeValue(forKey: oldest) {
                recent.removeFirst()
                cachedBytes -= removed.count
            }
            chunks[block] = data
            cachedBytes += data.count
        }
        recent.removeAll { $0 == block }
        recent.append(block)
        let start = offset - block
        return data.subdata(in: start..<(start + min(length, data.count - start)))
    }

    func clear() {
        chunks.removeAll()
        recent.removeAll()
        cachedBytes = 0
    }
}
