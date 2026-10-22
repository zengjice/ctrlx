#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct SettingsView: View {
        let onDone: () -> Void
        @Environment(IOSSettings.self) private var settings

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

                BackgroundMonitoringSettingsSection()

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
            .toolbar { doneButton }
        }

        private var doneButton: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onDone) {
                    Text("Done").fixedSize()
                }
            }
        }
    }

    private struct BackgroundMonitoringSettingsSection: View {
        @Environment(IOSSettings.self) private var settings
        @Environment(AgentBackgroundMonitoringService.self) private var backgroundMonitoring

        var body: some View {
            @Bindable var settings = settings

            Section {
                if #available(iOS 26.0, *) {
                    Toggle("Background Agent Monitoring", isOn: $settings.agentBackgroundMonitoringEnabled)
                        .accessibilityIdentifier("agent-background-monitoring-toggle")

                    switch backgroundMonitoring.monitoringStatus {
                    case .inactive:
                        if let failure = backgroundMonitoring.lastStartFailure {
                            Text("Could not start: \(failure)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else if settings.agentBackgroundMonitoringEnabled {
                            LabeledContent("Monitoring Status", value: "Ready")
                        }
                    case .starting:
                        LabeledContent("Monitoring Status", value: "Starting")
                    case .active:
                        LabeledContent("Monitoring Status", value: "Active")
                    }
                } else {
                    LabeledContent("Background Agent Monitoring", value: "Requires iOS 26")
                }
            } header: {
                Text("Background Activity")
            } footer: {
                Text("Starts when you send Agent input; stops when Agents finish or need your reply. iOS may end monitoring early. Send another input to start again.")
            }
        }
    }
#endif
