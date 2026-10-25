#if os(macOS)
    import CtrlxCommon
    import SwiftUI

    struct CtrlXAppUpdateBanner: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(AppSettings.self) private var settings
        @Environment(\.openSettings) private var openSettings

        private var service: CtrlXAppUpdateService {
            coordinator.ctrlXAppUpdateService
        }

        private var reminder: AgentUpdateReminderKey? {
            let state = service.state
            guard
                state.updateAvailable,
                let version = state.latestVersion,
                let build = state.latestBuild
            else { return nil }
            return .ctrlXApp(version: version, build: build)
        }

        var body: some View {
            if let reminder, coordinator.ctrlXAppUpdateReminders.shouldShow(reminder) {
                let state = service.state
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(
                            "A newer CtrlX is available: \(state.latestDisplayVersion).",
                            symbol: .arrowDownCircle
                        )
                        if let error = state.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if state.canInstall {
                        Button("Update and Relaunch") {
                            Task { await service.installAvailableUpdate() }
                        }
                        .disabled(service.isInstalling)
                    } else {
                        Button("Review in Settings…") {
                            settings.selectedSettingsTab = .general
                            openSettings()
                        }
                    }
                    Button("Dismiss") {
                        coordinator.ctrlXAppUpdateReminders.dismiss(reminder)
                    }
                }
                .font(.callout)
                .padding(10)
                .background(.bar)
                .accessibilityIdentifier("ctrlXAppUpdateBanner")
            }
        }
    }
#endif
