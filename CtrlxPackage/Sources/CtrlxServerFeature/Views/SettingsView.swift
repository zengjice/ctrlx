import AppKit
import CtrlxCommon
import CtrlxEncryption
import SwiftUI
import UniformTypeIdentifiers

/// Settings view for configuring the application
public struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    public init() { }

    public var body: some View {
        @Bindable var settings = settings

        TabView(selection: $settings.selectedSettingsTab) {
            Tab(value: SettingsTab.general) {
                GeneralSettingsView()
            } label: {
                Label("General", symbol: .gearshape)
            }
            Tab(value: SettingsTab.appearance) {
                AppearanceSettingsView()
            } label: {
                Label("Appearance", symbol: .circleLefthalfFilled)
            }
            Tab(value: SettingsTab.browser) {
                BrowserSettingsView()
            } label: {
                Label("Browser", symbol: .globe)
            }
            Tab(value: SettingsTab.sidebarLayout) {
                SidebarLayoutSettingsView()
            } label: {
                Label("Sidebar", symbol: .listBulletClipboard)
            }
            Tab(value: SettingsTab.editors) {
                EditorsSettingsView()
            } label: {
                Label("Editors", symbol: .pencil)
            }
            Tab(value: SettingsTab.remoteAccess) {
                RemoteAccessSettingsView()
            } label: {
                Label("Remote Access", symbol: .iphone)
            }
            Tab(value: SettingsTab.remoteHosts) {
                RemoteHostsSettingsView()
            } label: {
                Label("Remote Hosts", symbol: .laptopcomputer)
            }
            inputTabs
            Tab(value: SettingsTab.agents) {
                AgentsSettingsView()
            } label: {
                Label("Agents", symbol: .puzzlepiece)
            }
            Tab(value: SettingsTab.about) {
                AboutView()
            } label: {
                Label("About", symbol: .infoCircle)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 900, minHeight: 500)
    }

    @TabContentBuilder<SettingsTab> private var inputTabs: some TabContent<SettingsTab> {
        Tab(value: SettingsTab.quickPhraseSync) {
            QuickPhraseSyncSettingsView(store: settings.quickPhrases)
        } label: {
            Label("Quick Phrase Sync", symbol: .textBubbleFill)
        }
        Tab(value: SettingsTab.voiceInput) {
            Form {
                Section {
                    Text("Use the microphone beside the terminal quick actions to dictate into the focused pane. Audio is recognized on this Mac. Text is inserted without pressing Enter.")
                }
                VoiceCorrectionSettingsSection(settings: settings.voiceCorrection)
            }
            .formStyle(.grouped)
        } label: {
            Label("Voice Input", symbol: .micFill)
        }
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    @State private var launchAtLoginEnabled = false
    @State private var showingLoginItemError = false
    @State private var loginItemErrorMessage = ""

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Terminal") {
                Picker("Terminal App", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases, id: \.self) { app in
                        HStack {
                            Text(app.rawValue)
                            if app != .custom && !app.isInstalled {
                                Text("(not installed)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(app)
                    }
                }
                .help("Terminal application to use when attaching to sessions")

                if settings.terminalApp == .custom {
                    HStack {
                        Text("App Path")
                        TextField("Path to terminal app", text: $settings.customTerminalPath)
                        Button("Browse...") {
                            browseForTerminalApp(settings: settings)
                        }
                    }
                }

                Picker("Font", selection: $settings.fontName) {
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: AppSettings.minFontSize...AppSettings.maxFontSize, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Scrollback")
                    Spacer()
                    TextField("", value: $settings.scrollbackLines, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Text("lines")
                }

                Picker("Theme", selection: $settings.theme) {
                    ForEach(TerminalTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }

                Toggle("Highlight selected session in sidebar", isOn: $settings.highlightSelectedSidebarSession)
                    .help("Use a subtle theme-matched background behind the selected local or remote session")
            }

            Section("Behavior") {
                Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                    .help("Start CtrlX automatically when you log in")
                    .onChange(of: launchAtLoginEnabled) { _, newValue in
                        do {
                            try settings.setLoginItemEnabled(newValue)
                        } catch {
                            // Revert toggle state on failure
                            launchAtLoginEnabled = settings.isLoginItemEnabled
                            loginItemErrorMessage = error.localizedDescription
                            showingLoginItemError = true
                        }
                    }

                Toggle("Open sessions window on launch", isOn: $settings.openPanesWindowOnLaunch)
                    .help("Automatically open the sessions window when the app starts")

                Toggle("Show status bar", isOn: $settings.showStatusBar)

                Toggle("Auto-copy selected text", isOn: $settings.autoCopyOnSelect)
                    .help("Automatically copy selected text to the clipboard when the mouse is released")

                Toggle("Open clicked file links in a new tab", isOn: $settings.openClickedFileInNewTab)
                    .help("When a file:// link is clicked in the terminal, open the file in a new tab instead of the system default browser")

                Toggle("Always open files in split tab", isOn: $settings.alwaysOpenFilesInSplit)
                    .help("When opening a file in a new tab, route it to the split-view right pane instead of the left.")

                Toggle("Always open links in split tab", isOn: $settings.alwaysOpenLinksInSplit)
                    .help("When opening a web link in an in-app browser tab, route it to the split-view right pane instead of the left.")

                Toggle("Prevent sleep during active sessions", isOn: $settings.preventSleepDuringSessions)
                    .help("Keep host awake while Claude Code sessions are running")

                Toggle("Auto-reconnect on connection loss", isOn: $settings.autoReconnect)

                if settings.autoReconnect {
                    LabeledContent("Reconnect delay") {
                        HStack {
                            TextField("", value: $settings.reconnectDelay, format: .number)
                                .frame(width: 60)
                            Text("seconds")
                        }
                    }
                }
            }

            Section("Workspace Recovery") {
                Picker("Restore at startup", selection: $settings.workspaceRecoveryMode) {
                    Text("Layout, terminals and Agent conversations").tag(WorkspaceRecoveryMode.layoutAndAgents)
                    Text("Layout and terminals only").tag(WorkspaceRecoveryMode.layoutOnly)
                    Text("Off").tag(WorkspaceRecoveryMode.disabled)
                }
                Text("Restores saved workspaces after a restart. Existing tmux sessions stay running. Terminal commands and drafts are never sent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("tmux") {
                HStack {
                    TextField("Path to tmux", text: $settings.tmuxPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        browseForTmux(settings: settings)
                    }
                }

                HStack {
                    Text("Socket")
                    TextField("Default", text: $settings.tmuxSocket)
                        .help("Leave empty to use the default tmux socket")
                }
            }

            Section {
                Toggle("Debug Mode", isOn: $settings.debugModeEnabled)
                    .accessibilityIdentifier("debug-mode-toggle")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Show additional diagnostic information across CtrlX. Off by default on this device.")
                Text("On Mac, browser recording diagnostics are saved locally while enabled. Turning this off stops collection and keeps existing logs.")
            }

            CtrlXAppUpdateSettingsSection(service: coordinator.ctrlXAppUpdateService)
        }
        .formStyle(.grouped)
        .onAppear {
            // Sync with actual system state (in case user changed it in System Settings)
            launchAtLoginEnabled = settings.isLoginItemEnabled
        }
        .alert("Login Item Error", isPresented: $showingLoginItemError) {
            Button("OK") { }
        } message: {
            Text(loginItemErrorMessage)
        }
    }
}

private struct CtrlXAppUpdateSettingsSection: View {
    let service: CtrlXAppUpdateService

    var body: some View {
        let state = service.state

        Section {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle(for: state))
                        .font(.headline)

                    Text("Current version \(versionDescription(state.currentVersion, build: state.currentBuild))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = state.error, state.phase == .available || state.phase == .failed {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if let checkedAt = state.checkedAt {
                        Text("Last checked \(checkedAt, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                updateAction(for: state)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("CtrlX checks the signed installer feed automatically every 24 hours. Updating quits and relaunches the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func updateAction(for state: CtrlXAppUpdateState) -> some View {
        if state.phase == .checking {
            ProgressView()
                .controlSize(.small)
        } else if state.phase == .installing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing...")
                    .foregroundStyle(.secondary)
            }
        } else if state.updateAvailable {
            VStack(alignment: .trailing, spacing: 6) {
                Button("Update and Relaunch") {
                    Task { await service.installAvailableUpdate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.canInstall || service.isInstalling)

                Button("Check Again") {
                    Task { await service.refresh() }
                }
                .disabled(service.isInstalling)
            }
        } else {
            Button("Check Again") {
                Task { await service.refresh() }
            }
            .disabled(service.isInstalling)
        }
    }

    private func statusTitle(for state: CtrlXAppUpdateState) -> String {
        switch state.phase {
        case .idle:
            "Updates are checked automatically."
        case .checking:
            "Checking for updates..."
        case .upToDate:
            "CtrlX is up to date."
        case .available:
            "CtrlX \(state.latestDisplayVersion) is available."
        case .installing:
            "Installing CtrlX \(state.latestDisplayVersion)..."
        case .failed:
            "Could not check for updates."
        }
    }

    private func versionDescription(_ version: String, build: String?) -> String {
        if version.isEmpty {
            return build.map { "Build \($0)" } ?? "Unknown"
        }
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

// MARK: - Helpers

private var availableFonts: [String] {
    [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier New",
        "Andale Mono",
        "Source Code Pro",
        "Fira Code",
        "JetBrains Mono",
    ]
}

@MainActor
private func browseForTmux(settings: AppSettings) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
    panel.message = "Select the tmux executable"

    if panel.runModal() == .OK, let url = panel.url {
        settings.tmuxPath = url.path
    }
}

@MainActor
private func browseForTerminalApp(settings: AppSettings) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.message = "Select a terminal application"

    if panel.runModal() == .OK, let url = panel.url {
        settings.customTerminalPath = url.path
    }
}

#Preview {
    let settings = AppSettings()
    let e2eeService = E2EEService(keyPair: .generateNew())
    let coordinator = AppCoordinator(settings: settings)

    SettingsView()
        .environment(settings)
        .environment(coordinator)
        .environment(coordinator.licenseManager)
        .environment(PairingManager(settings: settings, e2eeService: e2eeService))
        .e2eeService(e2eeService)
}
