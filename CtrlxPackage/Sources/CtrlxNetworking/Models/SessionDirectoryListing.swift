import Foundation

public struct CreateSessionDirectory: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let parentDirectory: String
    public let name: String

    public init(parentDirectory: String, name: String) {
        self.parentDirectory = parentDirectory
        self.name = name
    }

    public var commandType: CommandType { .createSessionDirectory(self) }
}

/// One literal child name, never a path or a shell expression.
public enum SessionDirectoryName {
    public static func isValid(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name != "." && name != ".." && !name.contains("/")
            && name.utf8.count <= 255
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// Read-only, one-level directory lookup on the Host. A non-existent final path
/// component is a completion prefix; an existing directory lists its children.
public struct ListSessionDirectories: CommandSpec, Equatable {
    public typealias Response = CommandResponseMessage
    public let path: String
    public let includeHidden: Bool

    public init(path: String, includeHidden: Bool = false) {
        self.path = path
        self.includeHidden = includeHidden
    }

    public var commandType: CommandType { .listSessionDirectories(self) }
}

public struct SessionDirectoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let path: String
    public var id: String { path }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct SessionDirectoryListing: Codable, Sendable, Equatable {
    /// Absolute Host path, never resolved against a viewer's home directory.
    public let directory: String
    /// For a partial path, Up returns to the directory containing the matches.
    public let parentDirectory: String?
    public let isExactDirectory: Bool
    public let entries: [SessionDirectoryEntry]
    public let isTruncated: Bool

    public init(
        directory: String,
        parentDirectory: String?,
        isExactDirectory: Bool,
        entries: [SessionDirectoryEntry],
        isTruncated: Bool = false
    ) {
        self.directory = directory
        self.parentDirectory = parentDirectory
        self.isExactDirectory = isExactDirectory
        self.entries = entries
        self.isTruncated = isTruncated
    }
}
