import CtrlxNetworking
import Foundation

public struct AgentWorkflowCreatedAgent: Hashable, Sendable {
    public let paneID: String
    public let scope: WorkspaceIdentityScope
    public let pluginID: String

    public init(paneID: String, scope: WorkspaceIdentityScope, pluginID: String) {
        self.paneID = paneID
        self.scope = scope
        self.pluginID = pluginID
    }

    public func matches(_ instance: AgentWorkflowInstance) -> Bool {
        instance.hostID == scope.hostID && instance.workspacePane.serverID == scope.serverID
            && instance.paneID == paneID && instance.pluginID == pluginID
    }
}

/// Captures the destination before opening a launch form. Creation uses the
/// existing session/window launch paths; catalog discovery never retries it.
@MainActor
public struct AgentWorkflowAgentCreation {
    public struct Session: Identifiable, Sendable {
        public let name: String
        public let identity: WorkspacePaneIdentity
        public let directory: String
        public var id: UUID {
            identity.sessionID
        }

        public init(name: String, identity: WorkspacePaneIdentity, directory: String) {
            self.name = name
            self.identity = identity
            self.directory = directory
        }
    }

    public let hostID: UUID
    public let sessions: [Session]
    public let agents: [SessionLaunchAgent]
    public let directorySource: SessionDirectorySource
    public let launch: @MainActor (Session?, CreateTmuxWindow) async throws -> AgentWorkflowCreatedAgent

    public init(
        hostID: UUID, sessions: [Session], agents: [SessionLaunchAgent], directorySource: SessionDirectorySource,
        launch: @escaping @MainActor (Session?, CreateTmuxWindow) async throws -> AgentWorkflowCreatedAgent
    ) {
        self.hostID = hostID
        self.sessions = sessions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.agents = agents
        self.directorySource = directorySource
        self.launch = launch
    }

    public static func remote(
        hostID: UUID, pairID: String, connection: ViewerConnection?, store: SessionStore
    ) throws -> Self {
        guard
            let connection, connection.isHostConnected,
            connection.relayClient.hostAgentWorkflowVersion == AgentWorkflowWire.version,
            let catalog = connection.relayClient.workspaceInputState.catalog, catalog.scope.hostID == hostID else {
            throw AgentWorkflowError("The workflow Host is offline or its identity changed. Reload before creating an Agent.")
        }
        if let reason = store.agentWindowLaunchUnavailableReason(hostID: pairID, isConnected: true) {
            throw AgentWorkflowError(reason)
        }
        var seen: Set<UUID> = []
        let sessions = catalog.routes.values.sorted { $0.paneID < $1.paneID }.compactMap { route -> Session? in
            guard seen.insert(route.identity.sessionID).inserted else { return nil }
            let directory = store.paneStates[PaneKey(pairId: pairID, paneId: route.paneID)]?.currentPath ?? "~/"
            return Session(name: route.sessionName, identity: route.identity, directory: directory)
        }
        return Self(
            hostID: hostID, sessions: sessions,
            agents: store.launchAgents(for: pairID).filter { connection.relayClient.hostWorkflowAgentPluginIDs.contains($0.id) },
            directorySource: .remote(
                hostID: pairID, connection: connection,
                supportsBrowsing: store.hostsSupportingDirectoryBrowsing.contains(pairID),
                supportsCreation: store.hostsSupportingDirectoryCreation.contains(pairID)
            )
        ) { session, request in
            guard
                connection.isHostConnected,
                connection.relayClient.hostAgentWorkflowVersion == AgentWorkflowWire.version,
                connection.relayClient.workspaceInputState.catalog?.scope == catalog.scope,
                let pluginID = request.pluginID,
                connection.relayClient.hostWorkflowAgentPluginIDs.contains(pluginID) else {
                throw AgentWorkflowError("The Host changed. Reload before creating an Agent.")
            }
            let response: CommandResponseMessage
            if let session {
                let binding = ViewerWorkspaceInputBinding.session(pairID: pairID, hostID: hostID, identity: session.identity)
                response = try await connection.sendCommand(request, paneId: "", inputBinding: binding).get()
            } else {
                response = try await connection.sendCommand(CreateTmuxSession(
                    sessionName: request.sessionName, width: 120, height: 40,
                    workingDirectory: request.workingDirectory, pluginID: pluginID,
                    requireAgentLaunch: true, providerID: request.providerID
                ), paneId: "").get()
            }
            guard response.success, let paneID = response.paneId else {
                throw AgentWorkflowError(response.error ?? "The Host did not confirm creation. Check its tabs before trying again.")
            }
            // Window creation is guarded by the captured session binding. A new
            // session returns its own scope, including a freshly started server.
            let scope = session == nil ? response.createdPaneScope : catalog.scope
            guard let scope, scope.hostID == hostID, scope.serverID != nil else {
                throw AgentWorkflowError("The Agent may have been created, but its identity was not returned. Check the Host's tabs before trying again.")
            }
            await connection.relayClient.requestSessionState()
            return .init(paneID: paneID, scope: scope, pluginID: pluginID)
        }
    }
}
