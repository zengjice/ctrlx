import SwiftUI

public struct CheckForUpdatesView: View {
    private let coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let service = coordinator.ctrlXAppUpdateService
        let state = service.state

        if state.updateAvailable {
            Button("Update CtrlX to \(state.latestDisplayVersion)...") {
                Task { await service.installAvailableUpdate() }
            }
            .disabled(!state.canInstall || service.isInstalling)

            Button("Check for Updates Again") {
                Task { await service.refresh() }
            }
            .disabled(service.isInstalling)
        } else {
            Button(state.phase == .checking ? "Checking for Updates..." : "Check for Updates...") {
                Task { await service.refresh() }
            }
            .disabled(state.phase == .checking || service.isInstalling)
        }
    }
}
