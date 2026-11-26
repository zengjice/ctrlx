#if os(iOS)
    import CtrlxCommon
    import SwiftUI
    import UserNotifications

    struct SettingsView: View {
        let onDone: () -> Void
        @Environment(\.openURL) private var openURL
        @Environment(\.scenePhase) private var scenePhase
        @Environment(IOSSettings.self) private var settings
        @State private var pushService = PushNotificationService.shared

        var body: some View {
            @Bindable var settings = settings

            List {
                Section("Connection & Devices") {
                    NavigationLink {
                        ConnectionSettingsView()
                            .toolbar { doneButton }
                    } label: {
                        LabeledContent("Hosts & Connection") {
                            SettingsConnectionStatus()
                        }
                    }
                    .accessibilityIdentifier("connection-settings-link")
                }

                Section("Preferences") {
                    NavigationLink("Appearance & Terminal") {
                        TerminalAppearanceSettingsView()
                            .toolbar { doneButton }
                    }
                    .accessibilityIdentifier("terminal-appearance-settings-link")

                    NavigationLink("Keyboard & Input") {
                        TerminalInputSettingsView()
                            .toolbar { doneButton }
                    }
                    .accessibilityIdentifier("terminal-input-settings-link")

                    NavigationLink("Voice Input") {
                        List {
                            VoiceCorrectionSettingsSection(settings: settings.voiceCorrection)
                        }
                        .toolbar { doneButton }
                        .navigationTitle("Voice Input")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                    .accessibilityIdentifier("voice-input-settings-link")

                    NavigationLink("Quick Phrase Sync") {
                        QuickPhraseSyncSettingsView(store: settings.quickPhrases)
                            .toolbar { doneButton }
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    .accessibilityIdentifier("quick-phrase-sync-settings-link")

                    NavigationLink("New Session Defaults") {
                        NewSessionSettingsView()
                            .toolbar { doneButton }
                    }
                    .accessibilityIdentifier("new-session-settings-link")
                }

                Section("Notifications") {
                    LabeledContent("Notification Permission", value: notificationPermission)
                    LabeledContent("Push Token", value: pushService.isRegistered ? "Received" : "Not received")
                    if let error = pushService.registrationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button("Open notification settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                }

                Section {
                    Toggle("Debug Mode", isOn: $settings.debugModeEnabled)
                        .accessibilityIdentifier("debug-mode-toggle")

                    NavigationLink {
                        AboutSettingsView()
                            .toolbar { doneButton }
                    } label: {
                        LabeledContent("About CtrlX", value: AppBuildInfo.current.displayVersion)
                    }
                    .accessibilityIdentifier("about-settings-link")
                } header: {
                    Text("Other")
                } footer: {
                    Text("Debug Mode shows additional diagnostic information on this device.")
                }
            }
            .navigationTitle("Settings")
            .task(id: scenePhase) {
                if scenePhase == .active {
                    await pushService.updatePermissionStatus()
                }
            }
            .toolbar { doneButton }
        }

        private var doneButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onDone) {
                    Text("Done").fixedSize()
                }
            }
        }

        private var notificationPermission: String {
            switch pushService.permissionStatus {
            case .notDetermined: "Not requested"
            case .denied: "Denied"
            case .authorized: "Allowed"
            case .provisional: "Provisional"
            case .ephemeral: "Temporary"
            @unknown default: "Unknown"
            }
        }
    }
#endif
