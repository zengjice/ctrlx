import CtrlxCommon
import CtrlxNetworking
import Dependencies
import SwiftUI

/// Observe live status inside the always-mounted label, not the app's Scene body.
@MainActor
public struct MenuBarStatusLabel: View {
    private let windowManager: MirrorWindowManager
    private let remoteStore: SessionStore?
    private let dashboard: DashboardStore

    @Dependency(DockIconService.self) private var dockIconService

    public init(windowManager: MirrorWindowManager, remoteStore: SessionStore?, dashboard: DashboardStore) {
        self.windowManager = windowManager
        self.remoteStore = remoteStore
        self.dashboard = dashboard
    }

    public var body: some View {
        let pendingCount = totalPendingSessionCount
        MenuBarLabel(pendingCount: pendingCount, lowQuotaCount: dashboard.quotaSummaries().filter(\.isLow).count)
            .onChange(of: pendingCount, initial: true) { _, count in
                // Keep the service's activation-policy badge restoration.
                dockIconService.setBadgeCount(count)
            }
    }

    private var totalPendingSessionCount: Int {
        let localCount = windowManager.pendingSessionCount
        // Same-named sessions and pane numbers on different Hosts stay distinct.
        let remoteCount = remoteStore.map { store in
            Dictionary(grouping: store.paneStates, by: \.key.pairId)
                .values
                .reduce(0) { $0 + $1.map(\.value).pendingSessionCount }
        } ?? 0
        return localCount + remoteCount
    }
}
