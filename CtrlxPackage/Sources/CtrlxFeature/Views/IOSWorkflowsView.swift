#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    @MainActor
    struct IOSWorkflowsView: View {
        let openSession: (SessionNavigation) -> Void
        let navigation: AgentWorkflowNavigation
        @Environment(SessionStore.self) private var sessionStore
        @Environment(ViewerConnectionManager.self) private var connections
        @Environment(IOSFileBrowserWorkspaceStore.self) private var workspaces
        @Environment(IOSSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss
        @State private var error: String?
        @State private var opening = false

        var body: some View {
            AgentWorkflowsView(endpoints: endpoints, openAgent: openAgent, createAgent: createAgent, close: { dismiss() }, navigation: navigation)
                .preferredColorScheme(settings.appearanceMode.colorScheme)
                .alert("Could not open Agent", isPresented: Binding(get: { error != nil }, set: {
                    if !$0 {
                        error = nil
                    }
                })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }

        private func endpoints() -> [AgentWorkflowEndpoint] {
            settings.pairedHosts.map { .remote($0, manager: connections) }
        }

        private func createAgent(route: String, hostID: UUID) async throws -> AgentWorkflowAgentCreation {
            try .remote(hostID: hostID, pairID: route, connection: connections.connection(for: route), store: sessionStore)
        }

        private func openAgent(host: String, instance: AgentWorkflowInstance) {
            guard !opening, let endpoint = endpoints().first(where: { $0.id == host }) else { return }
            opening = true
            Task {
                defer { opening = false }
                do {
                    let current = try await endpoint.currentInstance(instance)
                    guard
                        let catalog = workspaces.catalogs[host], catalog.scope.hostID == current.hostID,
                        let reference = catalog.reference(paneID: current.paneID),
                        let route = catalog.resolve(reference), route.identity.isSamePane(as: current.workspacePane),
                        let window = sessionStore.windows(for: host).first(where: { $0.panes.contains(where: { $0.paneId == route.paneID }) }),
                        let workspace = workspaces.workspace(hostID: host, sessionName: route.sessionName) else {
                        throw AgentWorkflowError("Waiting for the Host’s current terminal layout. Try again.")
                    }
                    workspace.selectedID = nil
                    workspace.restoredWindowID = window.id
                    workspace.restoredPaneID = route.paneID
                    workspace.hasPendingTerminalSelection = false
                    workspaces.recordSelection(workspace: workspace, window: window, paneID: route.paneID)
                    workspaces.selectSession(reference.sessionReference)
                    openSession(.init(sessionName: route.sessionName, hostId: host, reference: reference.sessionReference))
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
#endif
