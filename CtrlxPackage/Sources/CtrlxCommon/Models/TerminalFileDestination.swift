import CtrlxNetworking
import Foundation

public struct TerminalFileDestination: Sendable, Equatable {
    public let directory: String
    public let file: String?

    public init(directory: String, file: String?) {
        self.directory = directory
        self.file = file
    }

    /// The Host resolves against the source agent's Git worktree, never a Viewer filesystem or shell cwd.
    @MainActor
    public static func resolve(path: String, context: RepositoryFileContext?, source: FileBrowserSource) async throws -> Self {
        if let reason = source.unavailableReason { throw FileBrowserError.message(reason) }
        guard RepositoryFileLink.isValid(path: path) else {
            throw FileBrowserError.message("Invalid repository-relative path.")
        }
        guard let context else {
            throw FileBrowserError.message("The source Agent's project directory is unavailable.")
        }
        guard case let .info(entry) = try await source.request(.repositoryInfo(path: path, context: context)), entry.path.hasPrefix("/") else {
            throw FileBrowserError.message("The Host returned no file information.")
        }
        try Task.checkCancellation()
        return entry.kind == .directory
            ? Self(directory: entry.path, file: nil)
            : Self(directory: (entry.path as NSString).deletingLastPathComponent, file: entry.path)
    }
}
