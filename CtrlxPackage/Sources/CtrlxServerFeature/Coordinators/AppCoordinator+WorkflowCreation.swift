import CtrlxCommon
import CtrlxNetworking
import CtrlxPluginProtocol
import Dependencies
import Foundation

extension AppCoordinator {
    func workflowAgentPluginIDs() -> [String] {
        localAgentLaunchAgents().map(\.id).filter { pluginRegistry?.core($0) is any AgentWorkflowProviding }
    }

    func workflowAgentCreation(hostID: UUID, creationID: UUID? = nil, firstWindowName: String? = nil) async throws -> AgentWorkflowAgentCreation {
        guard try await agentWorkflowService?.snapshot().hostID == hostID else {
            throw AgentWorkflowError(agentWorkflowStartupError ?? "The workflow Host is unavailable or changed. Reload before creating an Agent.")
        }
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
            guard try await agentWorkflowService?.snapshot().hostID == hostID else {
                throw AgentWorkflowError("The workflow Host is unavailable or changed. Reload before creating an Agent.")
            }
            let shortcutDefaults = newAgentModelShortcuts(pluginID: pluginID, providerID: request.providerID)
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
                    firstWindowName: firstWindowName ?? (creationID == nil ? (pluginRegistry?.manifest(pluginID)?.shortName ?? pluginID) : "Orbie"),
                    creationID: creationID
                )
                paneID = created.paneId
                serverID = created.serverID
            }
            _ = await tmuxService.refreshPanes()
            if let captured = try? await tmuxService.captureWorkspacePane(target: paneID), captured.identity.serverID == serverID {
                agentModelPreferences.initialize(.init(pane: captured.identity, defaults: shortcutDefaults), hostID: "local")
                await connectedViewerManager?.pushSessionStateToAll()
            }
            return .init(paneID: paneID, scope: .init(hostID: hostID, serverID: serverID), pluginID: pluginID)
        }
    }
}
