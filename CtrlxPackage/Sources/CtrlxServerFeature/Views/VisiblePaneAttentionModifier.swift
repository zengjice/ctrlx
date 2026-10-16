import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftUI

/// Installed on each rendered terminal tile, including the right split and
/// fallback layouts. File/browser tabs have no tile and therefore no reader.
struct VisiblePaneAttentionModifier: ViewModifier {
    let paneId: String
    var connection: ViewerConnection?

    @Environment(AppCoordinator.self) private var coordinator
    @State private var isVisible = false

    private var target: VisiblePaneAttention {
        if let connection {
            .remote(hostId: connection.id, paneId: paneId)
        } else {
            .local(paneId: paneId)
        }
    }

    private var canAcknowledge: Bool {
        guard let connection else { return true }
        return connection.isRelayConnected && connection.isHostConnected
    }

    func body(content: Content) -> some View {
        content
            .task {
                guard !Task.isCancelled else { return }
                isVisible = true
                markHandledIfActive()
            }
            .onDisappear { isVisible = false }
            .onChange(of: target) { markHandledIfActive() }
            .onChange(of: target.state(
                windowManager: coordinator.windowManager,
                remoteStore: coordinator.remoteSessionStore
            )) { markHandledIfActive() }
            .onChange(of: canAcknowledge) { markHandledIfActive() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                markHandledIfActive()
            }
    }

    private func markHandledIfActive() {
        guard
            canAcknowledge, target.markHandledIfNeeded(
                isVisible: isVisible,
                isAppActive: NSApp.isActive,
                windowManager: coordinator.windowManager,
                remoteStore: coordinator.remoteSessionStore
            ) else { return }

        // The acknowledgement has been accepted. Its synchronization must
        // finish even if the user switches tabs and tears down this tile.
        let binding = connection?.relayClient.workspaceInputState.binding(paneID: paneId)
        Task {
            if let connection {
                if case let .failure(error) = await connection.sendCommand(MarkHandled(), paneId: paneId, inputBinding: binding) {
                    print("Failed to mark remote pane \(paneId) handled on \(connection.id): \(error)")
                }
            } else {
                await coordinator.connectedViewerManager?.pushSessionStateToAll()
                await coordinator.broadcastBadgeDecreaseIfNeeded()
            }
        }
    }
}
