#if os(macOS)
    import CtrlxCommon
    import SwiftUI

    public struct MacDashboardView: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.openWindow) private var openWindow

        public init() { }

        public var body: some View {
            DashboardView(endpoints: {
                [DashboardEndpoint(
                    host: DashboardHost(id: "local", name: "This Mac", isLocal: true, isConnected: true, isSupported: true),
                    read: { try await coordinator.dashboardSnapshot() }
                )] + coordinator.settings.pairedHosts.map { .remote($0, manager: coordinator.viewerConnectionManager, usage: coordinator.remoteSessionStore?.usageOverview(for: $0.id)) }
            }, sessions: { host in
                if host == "local" {
                    return Set(coordinator.tmuxService.windows.map(\.sessionName)).sorted().map { .init(id: $0, title: $0) }
                }
                return coordinator.remoteSessionStore?.sessions(for: host).map { .init(id: $0.sessionName, title: $0.sessionName) } ?? []
            }, openSession: { host, session in
                if host == "local" {
                    guard let pane = coordinator.tmuxService.panes.first(where: { $0.sessionName == session }) else { return }
                    coordinator.pendingMenuBarSelection = .local(paneId: pane.paneId)
                } else {
                    guard let pane = coordinator.remoteSessionStore?.sessions(for: host).first(where: { $0.sessionName == session })?.activeWindow?.activePane else { return }
                    let name = coordinator.settings.pairedHosts.first(where: { $0.id == host })?.displayName ?? host
                    coordinator.pendingMenuBarSelection = .remote(hostId: host, hostName: name, paneId: pane.paneId)
                }
                openWindow(id: "panes")
            })
            .frame(minWidth: 440, minHeight: 400)
        }
    }
#endif
