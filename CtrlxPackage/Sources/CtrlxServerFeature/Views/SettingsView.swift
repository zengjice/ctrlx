import AppKit
import CtrlxCommon
import CtrlxEncryption
import SwiftUI
import UniformTypeIdentifiers

/// Settings view for configuring the application
public struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    static let minimumContentSize = CGSize(width: 760, height: 520)

    @State private var drafts = SettingsDrafts()
    @State private var searchQuery = ""
    @State private var searchRequest: SettingsSearchRequest?

    public init() { }

    public var body: some View {
        @Bindable var settings = settings

        NavigationSplitView {
            List(selection: Binding<SettingsTab?>(
                get: { settings.selectedSettingsTab },
                set: {
                    if let tab = $0 {
                        settings.selectedSettingsTab = tab
                    }
                }
            )) {
                ForEach(Self.tabs, id: \.self) { tab in
                    Label(tab.title, symbol: tab.symbol)
                        .accessibilityLabel("\(tab.title) settings")
                        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            page(settings.selectedSettingsTab) {
                selectedPage
            }
            .navigationTitle(settings.selectedSettingsTab.title)
            .frame(minWidth: 480)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: Self.minimumContentSize.width, maxWidth: .infinity, minHeight: Self.minimumContentSize.height, maxHeight: .infinity)
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search Settings")
        .searchSuggestions {
            let results = SettingsSearchItem.matching(searchQuery)
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, results.isEmpty {
                Text("No matching settings")
            }
            ForEach(results) { item in
                Button { navigate(to: item) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.tab.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onSubmit(of: .search) {
            if let item = SettingsSearchItem.matching(searchQuery).first {
                navigate(to: item)
            }
        }
        .background(SettingsWindowLifecycle {
            drafts.discard()
            searchQuery = ""
            searchRequest = nil
        })
    }

    private func navigate(to item: SettingsSearchItem) {
        settings.selectedSettingsTab = item.tab
        searchRequest = SettingsSearchRequest(item: item)
        searchQuery = ""
    }

    private func page<Content: View>(_ tab: SettingsTab, @ViewBuilder content: @escaping () -> Content) -> some View {
        let request = searchRequest?.item.tab == tab ? searchRequest : nil
        return ScrollViewReader { proxy in
            content()
                .environment(\.settingsSearchSection, request?.item.section)
                .environment(\.settingsSearchRequestID, request?.id)
                .task(id: request?.id) {
                    guard let section = request?.item.section else { return }
                    // Let the tab mount and any matching disclosure expand before scrolling.
                    await Task.yield()
                    proxy.scrollTo(section, anchor: .top)
                }
        }
    }

    private static let tabs: [SettingsTab] = [
        .general, .appearance, .browser, .sidebarLayout, .editors,
        .remoteAccess, .remoteHosts, .quickPhraseSync, .voiceInput, .agents, .about,
    ]

    @ViewBuilder private var selectedPage: some View {
        switch settings.selectedSettingsTab {
        case .general: GeneralSettingsView(drafts: drafts)
        case .appearance: AppearanceSettingsView()
        case .browser: BrowserSettingsView()
        case .sidebarLayout: SidebarLayoutSettingsView()
        case .editors: EditorsSettingsView()
        case .remoteAccess: RemoteAccessSettingsView()
        case .remoteHosts: RemoteHostsSettingsView()
        case .quickPhraseSync: QuickPhraseSyncSettingsView(store: settings.quickPhrases)
        case .voiceInput:
            Form {
                Section {
                    Text("Use the microphone beside the terminal quick actions to dictate into the focused pane. Audio is recognized on this Mac. Text is inserted without pressing Enter.")
                }
                VoiceCorrectionSettingsSection(settings: settings.voiceCorrection)
            }
            .formStyle(.grouped)
        case .agents: AgentsSettingsView(drafts: drafts)
        case .about: AboutView()
        }
    }
}

/// General settings tab
struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator

    @Bindable var drafts: SettingsDrafts

    @State private var launchAtLoginEnabled = false
    @State private var showingLoginItemError = false
    @State private var loginItemErrorMessage = ""

    var body: some View {
        @Bindable var settings = settings

        Form {
            FullDiskAccessSettingsSection()
                .settingsAnchor(.diskAccess)

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

                HStack {
                    Text("Scrollback")
                    Spacer()
                    TextField("", value: $settings.scrollbackLines, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Text("lines")
                }
            }

            .settingsAnchor(.terminal)

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

                Toggle("Prevent sleep during active sessions", isOn: $settings.preventSleepDuringSessions)
                    .help("Keep this Host awake while Agent sessions are running")
            }

            .settingsAnchor(.behavior)

            IPAFileAssociationSettingsSection()
                .settingsAnchor(.ipaAssociation)

            Section("Workspace Recovery") {
                Picker("Restore at startup", selection: $settings.workspaceRecoveryMode) {
                    Text("Layout, terminals and Agent conversations").tag(WorkspaceRecoveryMode.layoutAndAgents)
                    Text("Layout and terminals only").tag(WorkspaceRecoveryMode.layoutOnly)
                    Text("Off").tag(WorkspaceRecoveryMode.disabled)
                }
                Text("Restores saved workspaces after a restart. Existing tmux sessions stay running. Terminal commands and drafts are never sent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            .settingsAnchor(.recovery)

            AdvancedSettingsSection(drafts: drafts)
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

struct CtrlXAppUpdateSettingsSection: View {
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
            if let download = service.downloadProgress {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: download.fraction)
                        .frame(width: 160)
                    Text(download.isComplete ? "Installing..." : "Downloading \(download.percent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing...")
                        .foregroundStyle(.secondary)
                }
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
