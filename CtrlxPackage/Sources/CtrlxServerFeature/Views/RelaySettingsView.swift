import CtrlxCommon
import SwiftUI

struct RelaySettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(LicenseManager.self) private var licenseManager
    @State private var meteredRelay = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                TextField("Server URL", text: $settings.externalServerURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("relay-server-url")
                Toggle("Auto-connect on launch", isOn: $settings.autoConnectToServer)
            } header: {
                Text("Server")
            } footer: {
                Text("Shared by Remote Access and Remote Hosts on this Mac. Use WSS for a secure connection.")
            }
            .settingsAnchor(.relay)

            RemoteReconnectSettingsSection()

            RelayAccessSettingsSection(
                server: settings.externalServerURL, title: "This Mac · Relay Traffic",
                onMeteredChange: { meteredRelay = $0 }
            ) {
                await coordinator.connectedViewerManager?.enableReconnectAndRetryAll()
            }
            .settingsAnchor(.relayAccess)

            if !meteredRelay {
                Section {
                    licenseSection
                } header: {
                    Text("Relay Authorization")
                } footer: {
                    Text("Self-hosted relays do not require a key. If a custom relay requires one, obtain it from that relay's operator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .settingsAnchor(.relayAuthorization)
            }

            ViewerRelayAccessSettingsSections(
                server: settings.externalServerURL,
                hosts: settings.pairedHosts,
                restriction: { coordinator.viewerConnectionManager?.connection(for: $0)?.relayClient.relayAccessRestriction }
            ) { id in
                await coordinator.viewerConnectionManager?.connection(for: id)?.enableReconnectAndRetry()
            }
            .settingsAnchor(.relayTraffic)
        }
        .formStyle(.grouped)
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle("Relay")
        .task(id: settings.externalServerURL) {
            await licenseManager.loadStoredKey()
            await licenseManager.refreshStatus()
        }
    }

    // MARK: - License Section

    @ViewBuilder
    private var licenseSection: some View {
        @Bindable var licenseManager = licenseManager

        switch licenseManager.status?.state {
        case .notRequired:
            Label("Not required on this relay", symbol: .checkmarkCircleFill)
                .foregroundStyle(.secondary)
        case .active:
            LabeledContent("Status") {
                Text("Active")
                    .foregroundStyle(.green)
            }
            if
                let limit = licenseManager.status?.activationLimit,
                let usage = licenseManager.status?.activationUsage {
                LabeledContent("Activations", value: "\(usage) of \(limit) Macs")
            }
            Button("Deactivate This Mac", role: .destructive) {
                Task { await licenseManager.deactivate() }
            }
            .buttonStyle(.borderless)
        default:
            if let daysLeft = licenseManager.trialDaysLeft {
                LabeledContent("Status") {
                    Text("Trial — \(daysLeft) day\(daysLeft == 1 ? "" : "s") left")
                        .foregroundStyle(daysLeft <= 2 ? .orange : .secondary)
                }
            } else if licenseManager.status?.state == .expired {
                Label("Relay authorization required", symbol: .exclamationmarkTriangle)
                    .foregroundStyle(.orange)
            }
            TextField("License Key", text: $licenseManager.licenseKeyField)
                .textFieldStyle(.roundedBorder)
                // Unique AX label so E2E can focus the field itself — a bare
                // "License Key" query matches the row's static label first.
                .accessibilityLabel("License key field")
                .onSubmit {
                    Task { await licenseManager.activate() }
                }
            HStack {
                Button("Activate") {
                    Task { await licenseManager.activate() }
                }
                .disabled(licenseManager.actionState == .working)
            }
            if case let .error(message) = licenseManager.actionState {
                Label(message, symbol: .exclamationmarkTriangle)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
