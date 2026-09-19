import CtrlxCommon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct SessionDirectoryClient: Sendable {
    var resolve: @Sendable (_ path: String) async throws -> String
    var list: @Sendable (_ request: ListSessionDirectories) async throws -> SessionDirectoryListing
}

extension SessionDirectoryClient: DependencyKey {
    static let liveValue = Self(
        resolve: { try await SessionDirectoryResolver.shared.resolve($0) },
        list: { try await SessionDirectoryResolver.shared.list($0) }
    )
}

/// Filesystem checks run on the Host, off the UI actor, before creating tmux state.
actor SessionDirectoryResolver {
    static let shared = SessionDirectoryResolver()
    static let maximumResults = 200
    static let maximumEntryBytes = 128 * 1024

    func list(_ request: ListSessionDirectories) throws -> SessionDirectoryListing {
        try Task.checkCancellation()
        let files = FileManager.default
        guard
            request.path.utf8.count <= 4096,
            let path = SessionDirectoryPath.expanded(request.path, hostHome: files.homeDirectoryForCurrentUser.path)
        else { throw DirectoryError.invalidPath }

        var isDirectory: ObjCBool = false
        let exists = files.fileExists(atPath: path, isDirectory: &isDirectory)
        let exact = exists && isDirectory.boolValue
        let directory: String
        let prefix: String
        if exact {
            directory = try resolve(path)
            prefix = ""
        } else {
            // A slash means the user explicitly chose a directory; do not
            // silently fall back to a parent when it vanishes or is a file.
            guard !exists, !request.path.hasSuffix("/") else { throw DirectoryError.notDirectory(path) }
            directory = try resolve((path as NSString).deletingLastPathComponent)
            prefix = (path as NSString).lastPathComponent
        }

        let urls = try files.contentsOfDirectory(
            at: URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: request.includeHidden || prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        )
        var entries: [SessionDirectoryEntry] = []
        for url in urls {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            guard
                prefix.isEmpty || name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil,
                SessionDirectoryPath.isValid(url.path)
            else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            var childIsDirectory: ObjCBool = false
            let isFolder = values?.isDirectory == true
                || (values?.isSymbolicLink == true && files.fileExists(atPath: url.path, isDirectory: &childIsDirectory) && childIsDirectory.boolValue)
            guard isFolder else { continue }
            // FileManager may canonicalize /var → /private/var (and symlink
            // roots). Keep the user's chosen parent so Up reverses a click.
            let childPath = (directory as NSString).appendingPathComponent(name)
            entries.append(.init(name: name, path: childPath))
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Bound bytes as well as count: deeply nested paths and JSON escaping
        // must still fit the encrypted Relay frame without any server changes.
        let encoder = JSONEncoder()
        var bounded: [SessionDirectoryEntry] = []
        var byteCount = 0
        for entry in entries.prefix(Self.maximumResults) {
            let size = try encoder.encode(entry).count + 1
            guard byteCount + size <= Self.maximumEntryBytes else { break }
            bounded.append(entry)
            byteCount += size
        }
        return SessionDirectoryListing(
            directory: directory,
            parentDirectory: exact ? (directory == "/" ? nil : (directory as NSString).deletingLastPathComponent) : directory,
            isExactDirectory: exact,
            entries: bounded,
            isTruncated: entries.count > bounded.count
        )
    }

    /// Shared command handler, kept independent of tmux so browsing cannot
    /// accidentally create panes or invoke an agent.
    static func respond(to command: CommandMessage, request: ListSessionDirectories) async -> CommandResponseMessage {
        @Dependency(SessionDirectoryClient.self) var client
        do {
            let listing = try await client.list(request)
            return CommandResponseMessage(commandId: command.id, success: true, directoryListing: listing)
        } catch {
            return .failure(for: command.id, error: error.localizedDescription)
        }
    }

    func resolve(_ input: String) throws -> String {
        let files = FileManager.default
        guard let path = SessionDirectoryPath.expanded(input, hostHome: files.homeDirectoryForCurrentUser.path) else {
            throw DirectoryError.invalidPath
        }
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DirectoryError.notDirectory(path)
        }
        guard files.isReadableFile(atPath: path), files.isExecutableFile(atPath: path) else {
            throw DirectoryError.inaccessible(path)
        }
        return path
    }

    enum DirectoryError: Error, LocalizedError {
        case invalidPath
        case notDirectory(String)
        case inaccessible(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath: "Enter an absolute Host directory or ~/… without control characters."
            case let .notDirectory(path): "Directory does not exist on the Host: \(path)"
            case let .inaccessible(path): "Directory is not accessible on the Host: \(path)"
            }
        }
    }
}
