#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    @MainActor
    struct IOSDashboardView: View {
        let openSession: (String, String) -> Void
        @Environment(SessionStore.self) private var sessionStore
        @Environment(ViewerConnectionManager.self) private var connectionManager
        @Environment(IOSSettings.self) private var settings
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            DashboardView(endpoints: endpoints, sessions: sessions, openSession: { host, session in
                openSession(host, session)
                dismiss()
            }, close: { dismiss() })
        }

        private func endpoints() -> [DashboardEndpoint] {
            settings.pairedHosts.map { host in
                DashboardEndpoint.remote(host, manager: connectionManager, usage: sessionStore.usageOverview(for: host.id))
            }
        }

        private func sessions(_ host: String) -> [DashboardSessionLink] {
            sessionStore.sessions(for: host).map { DashboardSessionLink(id: $0.sessionName, title: $0.sessionName) }
        }
    }
#endif
