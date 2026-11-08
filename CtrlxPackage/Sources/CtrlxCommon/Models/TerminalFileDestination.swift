import CtrlxNetworking
import Foundation

public struct TerminalFileDestination: Sendable, Equatable {
    public let directory: String
    public let file: String?

    public init(directory: String, file: String?) {
        self.directory = directory
        self.file = file
    }

    /// The Host uses the source Agent's worktree root, or its project directory outside Git.
    @MainActor
    public static func resolve(path: String, context: RepositoryFileContext?, source: FileBrowserSource) async throws -> Self {
        if let reason = source.unavailableReason {
            throw FileBrowserError.message(reason)
        }
        guard RepositoryFileLink.isValid(path: path) else {
            throw FileBrowserError.message("Invalid workspace-relative path.")
        }
        guard let context else {
            throw FileBrowserError.message("The source Agent's project directory is unavailable.")
        }
        let response: FileBrowserResponse
        do {
            response = try await source.request(.repositoryInfo(path: path, context: context))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FileBrowserError.message("Cannot resolve Host file \"\(path)\" from Agent workspace \"\(context.projectDirectory)\": \(error.localizedDescription)")
        }
        guard case let .info(entry) = response, entry.path.hasPrefix("/") else {
            throw FileBrowserError.message("The Host returned no file information.")
        }
        try Task.checkCancellation()
        return entry.kind == .directory
            ? Self(directory: entry.path, file: nil)
            : Self(directory: (entry.path as NSString).deletingLastPathComponent, file: entry.path)
    }
}
