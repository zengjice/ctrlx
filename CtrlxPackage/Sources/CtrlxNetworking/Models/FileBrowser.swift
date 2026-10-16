import Foundation

/// File requests use the encrypted command channel, independently of terminal input.
public struct BrowseFiles: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let operation: FileBrowserOperation

    public init(_ operation: FileBrowserOperation) {
        self.operation = operation
    }

    public var commandType: CommandType {
        .browseFiles(self)
    }
}

public enum FileBrowserOperation: Codable, Sendable, Equatable {
    /// Host-owned tab identity; navigation and preview state stay client-local.
    case tabs(FileBrowserTabOperation)
    /// A nil path resolves the source pane's directory on the Host at open time.
    case list(path: String?, offset: Int, includeHidden: Bool)
    case info(path: String)
    case repositoryInfo(path: String, context: RepositoryFileContext)
    case read(path: String, offset: Int, revision: String)
    /// Explicit export, separate from bounded inline previews. Capability-gated on viewers.
    case download(path: String, offset: Int, revision: String)
    case upload(FileBrowserUploadOperation)
    case search(path: String, query: String, mode: FileBrowserSearchMode, includeHidden: Bool)

    /// These operations resolve a terminal source; explicit Host paths do not.
    public var usesSourcePane: Bool {
        switch self {
        case .tabs(.open),
             .list(nil, _, _),
             .repositoryInfo: true
        default: false
        }
    }
}

public enum FileBrowserSearchMode: String, Codable, Sendable, CaseIterable {
    case name
    case content
}

public enum FileBrowserKind: String, Codable, Sendable {
    case directory
    case text
    case markdown
    case image
    case pdf
    case unsupported
}

public enum FileBrowserLimits {
    public static let directoryPageSize = 200
    public static let maximumDirectoryEntries = 50_000
    public static let chunkBytes = 128 * 1_024
    public static let maximumPreviewBytes = 8 * 1_024 * 1_024
    public static let maximumTextBytes = 512 * 1_024
    public static let maximumDownloadBytes = 1_024 * 1_024 * 1_024
    public static let maximumUploadBytes = 1_024 * 1_024 * 1_024
    public static let maximumSearchResults = 200
    public static let maximumSearchEntries = 20_000
}

public struct FileBrowserEntry: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let kind: FileBrowserKind
    public let size: Int
    public let revision: String
    public let isSymbolicLink: Bool
    public var id: String {
        path
    }

    public init(path: String, name: String, kind: FileBrowserKind, size: Int, revision: String, isSymbolicLink: Bool = false) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.revision = revision
        self.isSymbolicLink = isSymbolicLink
    }
}

public struct FileBrowserListing: Codable, Sendable, Equatable {
    public let directory: String
    public let homeDirectory: String
    public let entries: [FileBrowserEntry]
    public let nextOffset: Int?
    public let revision: String

    public init(directory: String, homeDirectory: String, entries: [FileBrowserEntry], nextOffset: Int?, revision: String) {
        self.directory = directory
        self.homeDirectory = homeDirectory
        self.entries = entries
        self.nextOffset = nextOffset
        self.revision = revision
    }
}

public struct FileBrowserChunk: Codable, Sendable, Equatable {
    public let path: String
    public let revision: String
    public let offset: Int
    public let data: Data

    public init(path: String, revision: String, offset: Int, data: Data) {
        self.path = path
        self.revision = revision
        self.offset = offset
        self.data = data
    }
}

public struct FileBrowserSearchMatch: Codable, Sendable, Equatable, Identifiable {
    public let entry: FileBrowserEntry
    public let lineNumber: Int?
    public let lineText: String?
    public var id: String {
        "\(entry.path):\(lineNumber ?? 0)"
    }

    public init(entry: FileBrowserEntry, lineNumber: Int? = nil, lineText: String? = nil) {
        self.entry = entry
        self.lineNumber = lineNumber
        self.lineText = lineText
    }
}

public struct FileBrowserSearchResults: Codable, Sendable, Equatable {
    public let matches: [FileBrowserSearchMatch]
    /// Results or scan budget reached; refine the query to narrow the search.
    public let isTruncated: Bool

    public init(matches: [FileBrowserSearchMatch], isTruncated: Bool) {
        self.matches = matches
        self.isTruncated = isTruncated
    }
}

public enum FileBrowserResponse: Codable, Sendable, Equatable {
    case tab(HostFileTab)
    case tabClosed
    case listing(FileBrowserListing)
    case info(FileBrowserEntry)
    case chunk(FileBrowserChunk)
    case search(FileBrowserSearchResults)
    case uploaded(offset: Int, path: String?)
}

public enum PaneTabGroup: String, Codable, Sendable {
    case human
    case agent
}

public enum FileBrowserTabOperation: Codable, Sendable, Equatable {
    case open(sessionName: String, new: Bool)
    case close(id: UUID)
}

/// A live Host resource, never restored by rebinding a saved tmux pane ID.
public struct HostFileTab: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var sessionName: String
    public var windowID: String
    public let sourcePaneID: String
    public let group: PaneTabGroup
    public let isPrimary: Bool
    public let initialDirectory: String

    public init(
        id: UUID = UUID(),
        sessionName: String,
        windowID: String,
        sourcePaneID: String,
        group: PaneTabGroup = .human,
        isPrimary: Bool = true,
        initialDirectory: String
    ) {
        self.id = id
        self.sessionName = sessionName
        self.windowID = windowID
        self.sourcePaneID = sourcePaneID
        self.group = group
        self.isPrimary = isPrimary
        self.initialDirectory = initialDirectory
    }
}

/// IDs belong to one connection; a reconnect cannot resume an old upload.
public enum FileBrowserUploadOperation: Codable, Sendable, Equatable {
    case begin(id: UUID, directory: String, name: String, size: Int)
    case append(id: UUID, offset: Int, data: Data)
    case finish(id: UUID, sha256: String)
    case cancel(id: UUID)
}
