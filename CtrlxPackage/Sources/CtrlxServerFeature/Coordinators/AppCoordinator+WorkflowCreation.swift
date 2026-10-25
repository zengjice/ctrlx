import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func workflowAgentPluginIDs() -> [String] {
        localAgentLaunchAgents().map(\.id).filter { pluginRegistry?.core($0) is any AgentWorkflowProviding }
    }

    func workflowAgentCreation(hostID: UUID) async throws -> AgentWorkflowAgentCreation {
        _ = try await localWorkflowEndpoint().request(.catalog(offset: 0), hostID: hostID)
        var seen: Set<UUID> = []
        let sessions = tmuxService.panes.compactMap { pane -> AgentWorkflowAgentCreation.Session? in
            guard let identity = pane.workspaceIdentity, seen.insert(identity.sessionID).inserted else { return nil }
            return .init(name: pane.sessionName, identity: identity, directory: pane.currentPath)
        }
        return AgentWorkflowAgentCreation(
            hostID: hostID, sessions: sessions,
            agents: localAgentLaunchAgents().filter { workflowAgentPluginIDs().contains($0.id) },
            directorySource: .init(id: "local", create: { request in
                @Dependency(SessionDirectoryClient.self) var client
                return try await client.create(request)
            }) { request in
                @Dependency(SessionDirectoryClient.self) var client
                return try await client.list(request)
            }
        ) { [weak self] session, request in
            guard
                let self, let pluginID = request.pluginID,
                let core = pluginRegistry?.core(pluginID), core is any AgentWorkflowProviding else {
                throw AgentWorkflowError("The workflow Agent plugin is no longer available.")
            }
            _ = try await localWorkflowEndpoint().request(.catalog(offset: 0), hostID: hostID)
            let paneID: String
            let serverID: String
            if let session {
                paneID = try await TmuxWindowCreation.create(
                    request, core: core, tmux: tmuxService, expectedWorkspacePane: session.identity
                )
                serverID = session.identity.serverID
            } else {
                let prepared = try await SessionLaunchPreparation.prepare(
                    path: request.workingDirectory, pluginID: pluginID, requireAgentLaunch: true,
                    core: core, providerID: request.providerID
                )
                let launch = try tmuxService.agentLaunch(prepared)
                let created = try await tmuxService.createSession(
                    baseName: request.sessionName, width: 120, height: 40,
                    workingDirectory: prepared.workingDirectory,
                    runCommand: launch?.command, launchPayload: launch?.payload,
                    firstWindowName: pluginRegistry?.manifest(pluginID)?.shortName ?? pluginID
                )
                paneID = created.paneId
                serverID = created.serverID
            }
            _ = await tmuxService.refreshPanes()
            return .init(paneID: paneID, scope: .init(hostID: hostID, serverID: serverID), pluginID: pluginID)
        }
    }
}
