import AppKit
import CtrlxNetworking
import SwiftUI

public struct CheckForUpdatesView: View {
    private let coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        let service = coordinator.ctrlXAppUpdateService
        let state = service.state

        if service.isInstalling || state.phase == .installing {
            Button(installationStatus(for: state)) { }
                .disabled(true)
            Button("Show Update Status in Settings...") {
                openUpdateSettings()
            }
        } else if state.phase == .checking {
            Button("Checking for Updates...") { }
                .disabled(true)
        } else if state.updateAvailable {
            if state.canInstall {
                Button("Update CtrlX to \(state.latestDisplayVersion)...") {
                    presentAvailableUpdate(state)
                }
            } else {
                Button("Review CtrlX \(state.latestDisplayVersion) Update in Settings...") {
                    openUpdateSettings()
                }
            }
            Button("Check for Updates Again") {
                checkForUpdates()
            }
        } else {
            if state.phase == .upToDate {
                Button("CtrlX \(state.latestDisplayVersion) is up to date") { }
                    .disabled(true)
            } else if state.phase == .failed {
                Button("Update Check Failed — Review in Settings...") {
                    openUpdateSettings()
                }
            }

            Button("Check for Updates...") {
                checkForUpdates()
            }
        }
    }

    private func installationStatus(for state: CtrlXAppUpdateState) -> String {
        if state.phase == .installing {
            return "Installing CtrlX \(state.latestDisplayVersion)..."
        }
        return "Preparing CtrlX \(state.latestDisplayVersion) Update..."
    }

    private func checkForUpdates() {
        Task { @MainActor in
            await coordinator.ctrlXAppUpdateService.refresh()
            presentCheckResult(coordinator.ctrlXAppUpdateService.state)
        }
    }

    private func presentCheckResult(_ state: CtrlXAppUpdateState) {
        if state.updateAvailable {
            presentAvailableUpdate(state)
        } else if state.phase == .upToDate {
            presentUpToDate(state)
        } else if state.phase == .failed {
            presentCheckFailure(state)
        }
    }

    private func presentAvailableUpdate(_ state: CtrlXAppUpdateState) {
        guard state.canInstall else {
            openUpdateSettings()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Update CtrlX to \(state.latestDisplayVersion)?"
        alert.informativeText = """
        CtrlX will download and verify the update, then quit and relaunch automatically. \
        Save your work before continuing.
        """
        if let error = state.error {
            alert.informativeText += "\n\nThe last check reported: \(error)"
            alert.alertStyle = .warning
        } else {
            alert.alertStyle = .informational
        }
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        installAvailableUpdate(state)
    }

    private func installAvailableUpdate(_ state: CtrlXAppUpdateState) {
        guard let version = state.latestVersion, let build = state.latestBuild else { return }
        Task { @MainActor in
            do {
                try await coordinator.ctrlXAppUpdateService.install(version: version, build: build)
            } catch {
                presentInstallFailure(error)
            }
        }
    }

    private func presentUpToDate(_ state: CtrlXAppUpdateState) {
        let alert = NSAlert()
        alert.messageText = "CtrlX is up to date"
        alert.informativeText = "Version \(state.latestDisplayVersion) is the latest available version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentCheckFailure(_ state: CtrlXAppUpdateState) {
        presentFailure(
            title: "Could not check for updates",
            message: state.error ?? "The update check failed for an unknown reason."
        )
    }

    private func presentInstallFailure(_ error: any Error) {
        presentFailure(
            title: "Could not update CtrlX",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        )
    }

    private func presentFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Review in Settings...")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            openUpdateSettings()
        }
    }

    private func openUpdateSettings() {
        coordinator.settings.selectedSettingsTab = .general
        openSettings()
    }
}
