import CryptoKit
import CtrlxCommon
import CtrlxNetworking
import Foundation
import Testing
@testable import CtrlxServerFeature

struct HostFileUploadTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-upload-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test(arguments: [0, FileBrowserLimits.chunkBytes * 2 + 13])
    func publishesOnlyCompleteVerifiedFile(size: Int) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = HostFileUploads(), id = UUID()
        let name = "中文 file.bin"
        let path = root.appendingPathComponent(name)
        let data = Data(repeating: 0xBE, count: size)
        #expect(try await uploads.request(.begin(id: id, directory: root.path, name: name, size: size)) == .uploaded(offset: 0, path: nil))
        for offset in stride(from: 0, to: size, by: FileBrowserLimits.chunkBytes) {
            let end = min(size, offset + FileBrowserLimits.chunkBytes)
            #expect(try await uploads.request(.append(id: id, offset: offset, data: data.subdata(in: offset..<end))) == .uploaded(offset: end, path: nil))
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
        #expect(try await uploads.request(.finish(id: id, sha256: hash(data))) == .uploaded(offset: size, path: path.path))
        #expect(try Data(contentsOf: path) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [name])
        await uploads.shutdown()
    }

    @Test(arguments: ["existing", "late-file", "late-symlink", "checksum", "short", "offset", "large-chunk", "cancel", "expiry", "disconnect"])
    func failuresNeverReplaceFilesAndRemovePartialCopies(mode: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uploads = HostFileUploads(), id = UUID()
        let destination = root.appendingPathComponent("file")
        let original = Data("original".utf8)
        if mode == "existing" {
            try original.write(to: destination)
            await #expect(throws: (any Error).self) { try await uploads.request(.begin(id: id, directory: root.path, name: "file", size: 1)) }
        } else {
            _ = try await uploads.request(.begin(id: id, directory: root.path, name: "file", size: 1))
            switch mode {
            case "offset":
                await #expect(throws: (any Error).self) { try await uploads.request(.append(id: id, offset: 1, data: Data([1]))) }
            case "large-chunk":
                await #expect(throws: (any Error).self) { try await uploads.request(.append(id: id, offset: 0, data: Data(count: FileBrowserLimits.chunkBytes + 1))) }
            case "short":
                await #expect(throws: (any Error).self) { try await uploads.request(.finish(id: id, sha256: hash(Data()))) }
            case "cancel": _ = try await uploads.request(.cancel(id: id))
            case "expiry": #expect(await uploads.expire(now: .now + .seconds(61)) == false)
            case "disconnect":
                await uploads.shutdown()
                await #expect(throws: (any Error).self) { try await uploads.request(.begin(id: UUID(), directory: root.path, name: "late", size: 0)) }
            default:
                _ = try await uploads.request(.append(id: id, offset: 0, data: Data([1])))
                if mode == "late-file" { try original.write(to: destination) }
                if mode == "late-symlink" {
                    try original.write(to: root.appendingPathComponent("original"))
                    try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "original")
                }
                await #expect(throws: (any Error).self) {
                    try await uploads.request(.finish(id: id, sha256: mode == "checksum" ? "bad" : hash(Data([1]))))
                }
            }
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains { $0.hasPrefix(".ctrlx-upload-") })
        if ["existing", "late-file", "late-symlink"].contains(mode) { #expect(try Data(contentsOf: destination) == original) }
        else { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
        await uploads.shutdown()
    }

    @Test func unsafeNamesSizeAndCrossConnectionAccessAreRejected() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = HostFileUploads(), other = HostFileUploads(), id = UUID()
        for name in ["", ".", "..", "../escape", "/absolute", "bad\nname"] {
            await #expect(throws: (any Error).self) { try await first.request(.begin(id: UUID(), directory: root.path, name: name, size: 0)) }
        }
        for size in [-1, FileBrowserLimits.maximumUploadBytes + 1] {
            await #expect(throws: (any Error).self) { try await first.request(.begin(id: UUID(), directory: root.path, name: "file", size: size)) }
        }
        _ = try await first.request(.begin(id: id, directory: root.path, name: "file", size: 0))
        _ = try await other.request(.cancel(id: id))
        await #expect(throws: (any Error).self) { try await other.request(.finish(id: id, sha256: hash(Data()))) }
        _ = try await first.request(.finish(id: id, sha256: hash(Data())))
        #expect(try Data(contentsOf: root.appendingPathComponent("file")).isEmpty)
        await first.shutdown(); await other.shutdown()
    }

    @Test func changedDestinationAndConcurrentLimit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("directory"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let uploads = HostFileUploads(), ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            _ = try await uploads.request(.begin(id: id, directory: original.path, name: "file\(index)", size: 0))
        }
        await #expect(throws: (any Error).self) { try await uploads.request(.begin(id: UUID(), directory: original.path, name: "extra", size: 0)) }
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await uploads.request(.finish(id: ids[0], sha256: hash(Data()))) }
        await uploads.shutdown()
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
}
