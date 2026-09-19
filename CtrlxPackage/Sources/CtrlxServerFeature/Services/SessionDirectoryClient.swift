import CtrlxCommon
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
struct SessionDirectoryClient: Sendable {
    var resolve: @Sendable (_ path: String) async throws -> String
}

extension SessionDirectoryClient: DependencyKey {
    static let liveValue = Self(resolve: { try await SessionDirectoryResolver.shared.resolve($0) })
}

/// Filesystem checks run on the Host, off the UI actor, before creating tmux state.
actor SessionDirectoryResolver {
    static let shared = SessionDirectoryResolver()

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
