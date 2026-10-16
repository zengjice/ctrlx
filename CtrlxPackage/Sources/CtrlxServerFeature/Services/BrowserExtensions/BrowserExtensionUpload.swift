import CtrlxNetworking
import Foundation

/// One private package upload per extension control grant. Reuses the ordinary
/// uploader's chunk/checksum/atomic publication checks without accepting paths.
actor BrowserExtensionUpload {
    private let uploads = HostFileUploads()
    private let root: URL
    private var current: (id: UUID, file: URL)?
    private var closed = false

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ctrlx-extension-upload-\(UUID().uuidString)", isDirectory: true)) {
        self.root = root
    }

    func begin(id: UUID, name: String, size: Int) async throws {
        guard !closed, current == nil, size > 0, size <= BrowserExtensionPackage.Limits().archiveBytes else {
            throw BrowserExtensionPackageError("Choose one extension package of at most 64 MiB.")
        }
        let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard name.utf8.count <= 255, ["zip", "crx"].contains(suffix) else {
            throw BrowserExtensionPackageError("Choose a ZIP or CRX3 extension package.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("package.\(suffix)")
        current = (id, file)
        do {
            _ = try await uploads.request(.begin(id: id, directory: root.path, name: file.lastPathComponent, size: size))
            guard !closed else { throw CancellationError() }
        } catch {
            try await close()
            throw error
        }
    }

    func append(id: UUID, offset: Int, data: Data) async throws -> Int {
        guard !closed, current?.id == id else { throw BrowserExtensionPackageError("This extension upload expired.") }
        guard case let .uploaded(offset, _) = try await uploads.request(.append(id: id, offset: offset, data: data)) else {
            throw BrowserExtensionPackageError("The Host did not acknowledge the extension upload.")
        }
        return offset
    }

    func finish(id: UUID, sha256: String) async throws -> URL {
        guard !closed, let current, current.id == id else { throw BrowserExtensionPackageError("This extension upload expired.") }
        guard
            case let .uploaded(_, path) = try await uploads.request(.finish(id: id, sha256: sha256)),
            path == current.file.path, !closed else {
            throw BrowserExtensionPackageError("The Host did not confirm the complete extension package.")
        }
        return current.file
    }

    func close() async throws {
        closed = true
        await uploads.shutdown()
        if current != nil {
            try FileManager.default.removeItem(at: root)
            current = nil
        }
    }
}
