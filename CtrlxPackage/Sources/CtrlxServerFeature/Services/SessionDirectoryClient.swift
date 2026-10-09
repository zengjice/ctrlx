import CtrlxCommon
import CtrlxNetworking
import Darwin
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct SessionDirectoryClient: Sendable {
    var resolve: @Sendable (_ path: String) async throws -> String
    var list: @Sendable (_ request: ListSessionDirectories) async throws -> SessionDirectoryListing
    var create: @Sendable (_ request: CreateSessionDirectory) async throws -> String
}

extension SessionDirectoryClient: DependencyKey {
    static let liveValue = Self(
        resolve: { try await SessionDirectoryResolver.shared.resolve($0) },
        list: { try await SessionDirectoryResolver.shared.list($0) },
        create: { try await SessionDirectoryResolver.shared.create($0) }
    )
}

/// Filesystem checks run on the Host, off the UI actor, before creating tmux state.
actor SessionDirectoryResolver {
    static let shared = SessionDirectoryResolver()
    static let maximumResults = 200
    static let maximumEntryBytes = 128 * 1024

    func create(_ request: CreateSessionDirectory) throws -> String {
        try Task.checkCancellation()
        guard SessionDirectoryName.isValid(request.name) else { throw DirectoryError.invalidName }
        guard request.parentDirectory.utf8.count <= 4096 else { throw DirectoryError.invalidPath }
        let parent = try resolve(request.parentDirectory)
        let directory = (parent as NSString).appendingPathComponent(request.name)
        // mkdir is exclusive: an existing directory, file or symlink must fail.
        // No shell, intermediate parents, or overwriting an existing item.
        guard mkdir(directory, 0o777) == 0 else {
            let code = errno
            if code == EEXIST { throw DirectoryError.alreadyExists(request.name) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: directory])
        }
        return directory
    }

    static func respond(to command: CommandMessage, request: CreateSessionDirectory) async -> CommandResponseMessage {
        @Dependency(SessionDirectoryClient.self) var client
        do {
            let directory = try await client.create(request)
            return CommandResponseMessage(commandId: command.id, success: true, createdDirectory: directory)
        } catch {
            return .failure(for: command.id, error: error.localizedDescription)
        }
    }

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

        guard let handle = opendir(directory) else { throw DirectoryError.inaccessible(directory) }
        defer { closedir(handle) }
        let descriptor = dirfd(handle)
        let includeHidden = request.includeHidden || prefix.hasPrefix(".")
        var entries: [SessionDirectoryEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(handle) else {
                guard errno == 0 else { throw DirectoryError.inaccessible(directory) }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            let childPath = (directory as NSString).appendingPathComponent(name)
            guard
                name != ".", name != "..", includeHidden || !name.hasPrefix("."),
                prefix.isEmpty || name.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil,
                SessionDirectoryPath.isValid(childPath),
                Self.isDirectoryEntry(type: entry.pointee.d_type, name: name, descriptor: descriptor)
            else { continue }
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

    static func isDirectoryEntry(type: UInt8, name: String, descriptor: Int32) -> Bool {
        // Statting a mount point can wait indefinitely for a broken NFS server.
        // readdir already provides the type; inspect only links/unknown entries.
        if type == UInt8(DT_DIR) { return true }
        guard type == UInt8(DT_LNK) || type == UInt8(DT_UNKNOWN) else { return false }
        var value = stat()
        return fstatat(descriptor, name, &value, 0) == 0 && value.st_mode & S_IFMT == S_IFDIR
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

    enum DirectoryError: Error, LocalizedError, Equatable {
        case invalidPath
        case invalidName
        case alreadyExists(String)
        case notDirectory(String)
        case inaccessible(String)

        var errorDescription: String? {
            switch self {
            case .invalidPath: "Enter an absolute Host directory or ~/… without control characters."
            case .invalidName: "Enter one folder name, without / or control characters."
            case let .alreadyExists(name): "An item named \(name) already exists in this directory."
            case let .notDirectory(path): "Directory does not exist on the Host: \(path)"
            case let .inaccessible(path): "Directory is not accessible on the Host: \(path)"
            }
        }
    }
}
