#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import SwiftUI

    struct SessionWorkspaceDestination: View {
        let destination: SessionNavigation
        @Binding var initialSessionFit: NewSessionSizing.InitialFit?
        let automaticallyFitOnEntry: Bool
        @Environment(IOSFileBrowserWorkspaceStore.self) private var workspaces
        @Environment(ViewerConnectionManager.self) private var connections
        @Environment(IOSSettings.self) private var settings
        @State private var observedReference: ViewerWorkspaceReference?

        private var catalog: ViewerWorkspaceCatalog? {
            workspaces.catalogs[destination.hostId]
        }

        private var reference: ViewerWorkspaceReference? {
            destination.reference ?? observedReference
        }

        private var sessionName: String? {
            if let reference {
                return catalog?.resolve(reference)?.sessionName
            }
            return destination.sessionName
        }

        var body: some View {
            Group {
                if
                    let sessionName,
                    let connection = connections.connection(for: destination.hostId),
                    let workspace = workspaces.workspace(hostID: destination.hostId, sessionName: sessionName) {
                    WindowLayoutView(
                        sessionName: sessionName, hostId: destination.hostId,
                        relayClient: connection.relayClient, settings: settings, fileWorkspace: workspace,
                        initialSessionFit: $initialSessionFit, automaticallyFitOnEntry: automaticallyFitOnEntry
                    )
                    .id(workspace.recoveryID)
                } else {
                    ContentUnavailableView(
                        "Session Unavailable",
                        symbol: .exclamationmarkTriangle,
                        description: "The saved session will reconnect when its Host workspace is available."
                    )
                }
            }
            .onChange(of: catalog, initial: true) {
                if reference == nil {
                    observedReference = catalog?.reference(sessionName: destination.sessionName)
                }
            }
        }
    }
#endif
