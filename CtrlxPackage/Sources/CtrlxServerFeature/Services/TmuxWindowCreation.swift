import CtrlxNetworking
import Foundation
import GallagerPluginProtocol

/// One Host-side entry point for local UI and Viewer requests. Plugin commands
/// and environment never come from the Viewer. Validate before creating a pane.
enum TmuxWindowCreation {
    static func prepare(_ request: CreateTmuxWindow, core: (any PluginCore)?) async throws -> SessionLaunchPreparation {
        guard let pluginID = request.pluginID else {
            return SessionLaunchPreparation(workingDirectory: request.workingDirectory, launch: nil)
        }
        return try await SessionLaunchPreparation.prepare(
            path: request.workingDirectory,
            pluginID: pluginID,
            requireAgentLaunch: true,
            core: core
        )
    }

    @MainActor
    static func create(_ request: CreateTmuxWindow, core: (any PluginCore)?, tmux: TmuxService) async throws -> String {
        let prepared = try await prepare(request, core: core)
        let name = prepared.launch.map { URL(fileURLWithPath: $0.command).lastPathComponent }
        return try await tmux.newWindow(
            sessionName: request.sessionName,
            workingDirectory: prepared.workingDirectory,
            windowName: name,
            runCommand: prepared.runCommand,
            extraEnvironment: prepared.extraEnvironment
        )
    }
}
