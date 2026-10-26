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
            AgentWorkflowsView(endpoints: endpoints, openAgent: openAgent, createAgent: createAgent, navigation: coordinator.workflowNavigation)
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
                    let pane: PaneState?
                    if host == "local" {
                        pane = coordinator.windowManager.paneStates[current.paneID]
                    } else {
                        pane = coordinator.remoteSessionStore?.paneState(for: current.paneID, hostId: host)
                    }
                    guard
                        let pane, current.workspacePane.isSamePane(as: pane.workspaceIdentity),
                        host == "local" || coordinator.remoteSessionStore?.workspaceCatalogsByHost[host]?.scope.hostID == current.hostID else {
                        throw AgentWorkflowError("Waiting for the Host’s current terminal layout. Try again.")
                    }
                    coordinator.detachedWindows.sourcePaneRequest = .init(hostID: host == "local" ? nil : host, pane: pane)
                    let owner = coordinator.detachedWindows.owner(hostID: host == "local" ? nil : host, windowID: pane.stableWindowId)
                    if !coordinator.detachedWindows.focusNativeWindow(workspaceID: owner) {
                        if let owner {
                            openWindow(id: "detached-terminal", value: owner)
                        } else {
                            openWindow(id: "panes")
                        }
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
#endif
