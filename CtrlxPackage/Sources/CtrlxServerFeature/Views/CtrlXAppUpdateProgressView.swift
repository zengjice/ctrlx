#if os(macOS)
    import CtrlxNetworking
    import SwiftUI

    /// Foreground status window for an explicitly requested CtrlX update.
    ///
    /// The detached installer writes progress to its own log, so this window
    /// deliberately uses an indeterminate indicator rather than inventing a
    /// download percentage.
    public struct CtrlXAppUpdateProgressView: View {
        public static let windowID = "ctrlx-app-update-progress"

        private let coordinator: AppCoordinator

        @Environment(\.dismissWindow) private var dismissWindow
        @Environment(\.openSettings) private var openSettings

        public init(coordinator: AppCoordinator) {
            self.coordinator = coordinator
        }

        private var service: CtrlXAppUpdateService {
            coordinator.ctrlXAppUpdateService
        }

        public var body: some View {
            let state = service.state
            let failure = activeInstallationError

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(title(for: state, failure: failure))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(message(for: state, failure: failure))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel("Updating CtrlX")
                }

                HStack(spacing: 10) {
                    if failure != nil {
                        if state.canInstall {
                            Button("Try Again") {
                                Task { await service.installAvailableUpdate() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Review in Settings...") {
                                coordinator.settings.selectedSettingsTab = .general
                                openSettings()
                                dismissWindow(id: Self.windowID)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    Button("Hide") {
                        dismissWindow(id: Self.windowID)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 460)
            .accessibilityIdentifier("ctrlXAppUpdateProgress")
        }

        private var activeInstallationError: String? {
            guard service.state.phase != .installing, !service.isInstalling else { return nil }
            return service.installationError
        }

        private func title(for state: CtrlXAppUpdateState, failure: String?) -> String {
            if failure != nil {
                return "Update Could Not Complete"
            }

            switch state.phase {
            case .installing:
                return "Installing CtrlX \(state.latestDisplayVersion)"
            case .checking:
                return "Checking for Updates..."
            case .upToDate:
                return "CtrlX Is Up to Date"
            case .failed:
                return "Could Not Check for Updates"
            case .idle,
                 .available:
                return "Preparing CtrlX \(state.latestDisplayVersion)"
            }
        }

        private func message(for state: CtrlXAppUpdateState, failure: String?) -> String {
            if failure != nil {
                return "The update did not complete. You can retry, or review the update settings."
            }

            switch state.phase {
            case .installing:
                return "The signed update is being installed. CtrlX will quit and reopen automatically."
            case .checking:
                return "Contacting the signed update feed..."
            case .upToDate:
                return "Version \(state.latestDisplayVersion) is the latest available version."
            case .failed:
                return "Review the update status in Settings."
            case .idle,
                 .available:
                return "Downloading and verifying the signed update before installation."
            }
        }
    }
#endif
