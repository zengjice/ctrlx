import CryptoKit
import Foundation
import Testing
@testable import CtrlxServerFeature

@Suite("Browser extension uploads")
struct BrowserExtensionUploadTests {
    @Test
    func completePackageIsPrivateAndBoundToUploadID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let upload = BrowserExtensionUpload(root: root)
        let id = UUID(), data = Data("private fixture ZIP bytes".utf8)
        try await upload.begin(id: id, name: "../../outside.zip", size: data.count)
        await #expect(throws: (any Error).self) { try await upload.append(id: UUID(), offset: 0, data: data) }
        #expect(try await upload.append(id: id, offset: 0, data: data) == data.count)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("package.zip").path))
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = try await upload.finish(id: id, sha256: checksum)
        #expect(file == root.appendingPathComponent("package.zip"))
        #expect(try Data(contentsOf: file) == data)
        try await upload.close()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await #expect(throws: (any Error).self) { try await upload.finish(id: id, sha256: checksum) }
    }

    @Test(arguments: [0, 64 * 1_024 * 1_024 + 1])
    func rejectsSizeBeforeCreatingFiles(size: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let upload = BrowserExtensionUpload(root: root)
        await #expect(throws: (any Error).self) { try await upload.begin(id: UUID(), name: "fixture.zip", size: size) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try await upload.close()
    }

    @Test
    func checksumFailureDoesNotPublishPackage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let upload = BrowserExtensionUpload(root: root)
        let id = UUID()
        try await upload.begin(id: id, name: "fixture.crx", size: 3)
        _ = try await upload.append(id: id, offset: 0, data: Data([1, 2, 3]))
        await #expect(throws: (any Error).self) { try await upload.finish(id: id, sha256: String(repeating: "0", count: 64)) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("package.crx").path))
        try await upload.close()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func closingIncompleteUploadRemovesOnlyItsOwnDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let upload = BrowserExtensionUpload(root: root)
        let id = UUID()
        try await upload.begin(id: id, name: "fixture.zip", size: 10)
        _ = try await upload.append(id: id, offset: 0, data: Data([1]))
        try await upload.close()
        try await upload.close()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        await #expect(throws: (any Error).self) { try await upload.begin(id: UUID(), name: "fixture.zip", size: 10) }
    }
}
