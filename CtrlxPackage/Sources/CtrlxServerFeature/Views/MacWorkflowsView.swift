#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    public struct MacWorkflowsView: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.openWindow) private var openWindow
        @State private var error: String?
        @State private var opening = false

        public init() { }

        public var body: some View {
            AgentWorkflowsView(endpoints: endpoints, openAgent: openAgent, createAgent: createAgent)
                .frame(minWidth: 560, minHeight: 480)
                .alert("Could not open Agent", isPresented: Binding(get: { error != nil }, set: {
                    if !$0 {
                        error = nil
                    }
                })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }

        private func endpoints() -> [AgentWorkflowEndpoint] {
            [coordinator.localWorkflowEndpoint()] + coordinator.settings.pairedHosts.map {
                .remote($0, manager: coordinator.viewerConnectionManager)
            }
        }

        private func createAgent(route: String, hostID: UUID) async throws -> AgentWorkflowAgentCreation {
            if route == "local" {
                return try await coordinator.workflowAgentCreation(hostID: hostID)
            }
            guard let store = coordinator.remoteSessionStore else { throw AgentWorkflowError("The Host is unavailable.") }
            return try .remote(
                hostID: hostID, pairID: route,
                connection: coordinator.viewerConnectionManager?.connection(for: route), store: store
            )
        }

        private func openAgent(host: String, instance: AgentWorkflowInstance) {
            guard !opening, let endpoint = endpoints().first(where: { $0.id == host }) else { return }
            opening = true
            Task {
                defer { opening = false }
                do {
                    let current = try await endpoint.currentInstance(instance)
                    if host == "local" {
                        guard
                            coordinator.tmuxService.panes.contains(where: {
                                $0.paneId == current.paneID && current.workspacePane.isSamePane(as: $0.workspaceIdentity)
                            }) else { throw AgentWorkflowError("The Agent’s terminal is no longer available.") }
                        coordinator.pendingMenuBarSelection = .local(paneId: current.paneID)
                    } else {
                        guard
                            let catalog = coordinator.remoteSessionStore?.workspaceCatalogsByHost[host],
                            catalog.scope.hostID == current.hostID,
                            let route = catalog.routes[current.workspacePane.paneID],
                            route.identity.isSamePane(as: current.workspacePane) else {
                            throw AgentWorkflowError("Waiting for the Host’s current terminal layout. Try again.")
                        }
                        coordinator.pendingMenuBarSelection = .remote(hostId: host, hostName: endpoint.name, paneId: route.paneID)
                    }
                    openWindow(id: "panes")
                } catch { self.error = error.localizedDescription }
            }
        }
    }
#endif
