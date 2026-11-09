import CtrlxCommon
import Dependencies
import Foundation

struct TmuxSettingsDraft: Equatable, Sendable {
    var tmuxPath: String
    var socketPath: String

    func validated() async throws -> Self {
        let socket = (socketPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard socket.isEmpty || (socket.hasPrefix("/") && !socket.containsControlCharacters) else {
            throw SettingsConfigurationError.invalidSocket
        }
        let path = try await SettingsCommandValidation.resolve(tmuxPath)
        return Self(tmuxPath: path, socketPath: socket)
    }
}

enum SettingsConfigurationError: Error, LocalizedError {
    case invalidCommand
    case invalidSocket

    var errorDescription: String? {
        switch self {
        case .invalidCommand: "Enter an executable path or a command available on PATH."
        case .invalidSocket: "Enter an absolute socket path, or leave it empty to use the default."
        }
    }
}

enum SettingsCommandValidation {
    static func resolve(_ input: String, preserveCommandName: Bool = false) async throws -> String {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.containsControlCharacters else {
            throw SettingsConfigurationError.invalidCommand
        }
        @Dependency(AgentResumeExecutableClient.self) var executables
        let path = try await executables.resolve(nil, (command as NSString).expandingTildeInPath)
        // A bare Agent command should keep following PATH after CLI updates.
        return preserveCommandName && !command.contains("/") ? command : path
    }
}

private extension String {
    var containsControlCharacters: Bool {
        unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
