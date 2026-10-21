#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct ConnectionSettingsView: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager

        /// In-flight edit buffer for the device name field. Synced to/from
        /// `settings.deviceName` so the field shows the system name when no
        /// custom name is set.
        @State private var deviceNameDraft = ""

        /// The device name that was committed to settings on the last edit.
        /// Used to detect whether the user actually changed the name when the
        /// field loses focus, so we only reconnect when something differs.
        @State private var lastCommittedDeviceName = ""

        /// Tracks focus on the device-name field so we can also commit when
        /// the user dismisses the keyboard by tapping elsewhere — `onSubmit`
        /// alone would silently discard the draft.
        @FocusState private var deviceNameFieldFocused: Bool

        var body: some View {
            Form {
                // Connection Status Section
                Section("Connection") {
                    @Bindable var settings = settings
                    LabeledContent("Status") {
                        SettingsConnectionStatus()
                    }

                    if !connectionManager.anyHostConnected {
                        Button("Connect All") {
                            Task {
                                guard let serverURL = URL(string: settings.externalServerURL) else { return }
                                await connectionManager.connectAll(
                                    pairedHosts: settings.pairedHosts,
                                    serverURL: serverURL,
                                    deviceId: settings.deviceId,
                                    deviceName: settings.deviceName
                                )
                            }
                        }
                    } else {
                        Button("Disconnect All") {
                            Task {
                                await connectionManager.disconnectAll()
                            }
                        }
                    }
                    Toggle("Auto-connect on launch", isOn: $settings.autoReconnect)
                }

                // Device Name Section
                Section {
                    TextField(settings.systemDeviceName, text: $deviceNameDraft)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($deviceNameFieldFocused)
                        .onSubmit { commitDeviceName() }
                        .onChange(of: deviceNameFieldFocused) { _, isFocused in
                            if !isFocused {
                                commitDeviceName()
                            }
                        }
                        .accessibilityIdentifier("device-name-field")
                } header: {
                    Text("Device Name")
                } footer: {
                    Text("Shown to the Macs you've paired with. Leave blank to use the system name (\(settings.systemDeviceName)).")
                }

                // Paired Hosts Section
                Section {
                    NavigationLink {
                        ManageHostsView()
                    } label: {
                        HStack {
                            Text("Paired Hosts")
                            Spacer()
                            Text("\(settings.pairedHosts.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Server Section
                Section("Relay Server") {
                    @Bindable var settings = settings
                    TextField("Server URL", text: $settings.externalServerURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Hosts & Connection")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                deviceNameDraft = settings.customDeviceName ?? ""
                lastCommittedDeviceName = deviceNameDraft
            }
            .onDisappear {
                // SwiftUI tears down the view (and `@FocusState`) when the
                // sheet dismisses, so `.onChange(of: deviceNameFieldFocused)`
                // can't be relied on as the only commit trigger. Commit any
                // pending edit here so closing the sheet preserves the name.
                commitDeviceName()
            }
        }

        /// Persist the edited device name and push the update to paired hosts.
        ///
        /// Treats whitespace-only input as "clear back to system name" by
        /// storing `nil`, which makes `IOSSettings.deviceName` fall back to
        /// `UIDevice.current.name`. To propagate the change to already-connected
        /// hosts, disconnects and reconnects all of them — the new name rides
        /// along on the next `RegisterViewerMessage`.
        private func commitDeviceName() {
            let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != lastCommittedDeviceName else {
                return
            }

            settings.customDeviceName = trimmed.isEmpty ? nil : trimmed
            lastCommittedDeviceName = trimmed

            // Push the new name to any currently connected hosts by reconnecting.
            guard
                settings.isPaired,
                let serverURL = URL(string: settings.externalServerURL)
            else { return }

            Task {
                await connectionManager.disconnectAll()
                await connectionManager.connectAll(
                    pairedHosts: settings.pairedHosts,
                    serverURL: serverURL,
                    deviceId: settings.deviceId,
                    deviceName: settings.deviceName
                )
            }
        }
    }

    struct SettingsConnectionStatus: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(ViewerConnectionManager.self) private var connectionManager

        var body: some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(connectionStatusText)
                    .foregroundStyle(.secondary)
            }
        }

        private var connectionStatusColor: Color {
            if connectionManager.anyHostConnected {
                return .green
            } else if connectionManager.isConnecting {
                return .yellow
            } else {
                return .gray
            }
        }

        private var connectionStatusText: String {
            let connectedCount = connectionManager.activeConnections.filter(\.isHostConnected).count
            let totalCount = settings.pairedHosts.count

            if totalCount == 0 {
                return "No Hosts"
            } else if connectedCount > 0 {
                return "\(connectedCount)/\(totalCount) Online"
            } else if connectionManager.isConnecting {
                return "Connecting..."
            } else {
                return "0/\(totalCount) Online"
            }
        }
    }
#endif
