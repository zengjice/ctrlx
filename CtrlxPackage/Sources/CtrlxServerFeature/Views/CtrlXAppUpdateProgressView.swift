#if os(macOS)
    import CtrlxNetworking
    import SwiftUI

    /// Foreground status window for an explicitly requested CtrlX update.
    ///
    /// Shows the detached installer's actual download progress when the Host
    /// can determine the artifact size, with an indeterminate fallback.
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
            let download = service.downloadProgress

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(title(for: state, failure: failure, download: download))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(message(for: state, failure: failure, download: download))
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
                } else if let download {
                    VStack(spacing: 8) {
                        ProgressView(value: download.fraction)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 360)
                            .animation(.linear(duration: 0.2), value: download.fraction)
                            .accessibilityLabel("Update download progress")
                            .accessibilityValue("\(download.percent) percent")

                        HStack {
                            Text(download.isComplete ? "Download complete" : "\(download.percent)%")
                            Spacer()
                            Text("\(download.downloadedBytes.formatted(.byteCount(style: .file))) of \(download.totalBytes.formatted(.byteCount(style: .file)))")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                    }
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

        private func title(
            for state: CtrlXAppUpdateState,
            failure: String?,
            download: CtrlXAppUpdateService.DownloadProgress?
        ) -> String {
            if failure != nil {
                return "Update Could Not Complete"
            }

            switch state.phase {
            case .installing:
                return download?.isComplete == true
                    ? "Installing CtrlX \(state.latestDisplayVersion)"
                    : "Downloading CtrlX \(state.latestDisplayVersion)"
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

        private func message(
            for state: CtrlXAppUpdateState,
            failure: String?,
            download: CtrlXAppUpdateService.DownloadProgress?
        ) -> String {
            if failure != nil {
                return "The update did not complete. You can retry, or review the update settings."
            }

            switch state.phase {
            case .installing:
                if download?.isComplete == true {
                    return "Download complete. Verifying and installing the signed update. CtrlX will quit and reopen automatically."
                }
                return "Downloading the signed update. CtrlX will quit and reopen automatically when installation completes."
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
