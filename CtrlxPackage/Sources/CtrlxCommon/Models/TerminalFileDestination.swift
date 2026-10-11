import CtrlxNetworking
import Foundation

public struct TerminalFileDestination: Sendable, Equatable {
    public let directory: String
    public let file: String?

    public init(directory: String, file: String?) {
        self.directory = directory
        self.file = file
    }

    /// Resolves an already recognized/decoded Host path, not raw terminal text or a URL.
    @MainActor
    public static func resolve(path: String, baseDirectory: String?, source: FileBrowserSource) async throws -> Self {
        if let reason = source.unavailableReason { throw FileBrowserError.message(reason) }
        guard !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FileBrowserError.message("Invalid Host file path.")
        }
        let absolute: String
        if path.hasPrefix("/") || path.hasPrefix("~/") { absolute = path }
        else {
            guard let baseDirectory, baseDirectory.hasPrefix("/") else {
                throw FileBrowserError.message("The source pane's directory is unavailable. Use an absolute Host path.")
            }
            absolute = (baseDirectory as NSString).appendingPathComponent(path)
        }
        guard case let .info(entry) = try await source.request(.info(path: absolute)), entry.path.hasPrefix("/") else {
            throw FileBrowserError.message("The Host returned no file information.")
        }
        try Task.checkCancellation()
        return entry.kind == .directory
            ? Self(directory: entry.path, file: nil)
            : Self(directory: (entry.path as NSString).deletingLastPathComponent, file: entry.path)
    }
}
