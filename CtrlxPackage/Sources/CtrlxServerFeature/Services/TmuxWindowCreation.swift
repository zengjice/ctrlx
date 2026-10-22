import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation

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
            core: core,
            providerID: request.providerID
        )
    }

    @MainActor
    static func create(_ request: CreateTmuxWindow, core: (any PluginCore)?, tmux: TmuxService, expectedWorkspacePane: WorkspacePaneIdentity? = nil) async throws -> String {
        let identity = expectedWorkspacePane ?? tmux.panes.first { $0.sessionName == request.sessionName }?.workspaceIdentity
        let prepared = try await prepare(request, core: core)
        let name = prepared.launch.map { URL(fileURLWithPath: $0.command).lastPathComponent }
        let agentLaunch = try tmux.agentLaunch(prepared)
        return try await tmux.newWindow(
            sessionName: request.sessionName,
            workingDirectory: prepared.workingDirectory,
            windowName: name,
            runCommand: agentLaunch?.command,
            launchPayload: agentLaunch?.payload,
            expectedWorkspacePane: identity
        )
    }
}
