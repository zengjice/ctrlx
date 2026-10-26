#if os(macOS)
    import AppKit
    import ClaudeCodePluginCore
    import CodexPluginCore
    import CtrlxCommon
    import CtrlxEncryption
    import CtrlxNetworking
    import CtrlxPluginProtocol
    import Dependencies
    import SwiftUI
    import UniformTypeIdentifiers

    // MARK: - AgentsSettingsView

    /// Settings tab listing all registered agent plugins (Claude Code, Codex CLI, …)
    /// with a segmented picker and per-agent form. Thin MV view — all data/actions go
    /// through `AppCoordinator`.
    public struct AgentsSettingsView: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.openWindow) private var openWindow

        @State private var selectedAgentID = ""
        /// Single source-of-truth driving the Add-Plugin sheet (URL or zip). Two
        /// sibling `.sheet` modifiers can be flaky on macOS (one may fail to
        /// present), so both flows funnel through one `.sheet(item:)`.
        @State private var addPlugin: AddPluginPresentation?
        @State private var pluginToRemove: String?
        @State private var showRemoveConfirmation = false

        public init() { }

        public var body: some View {
            VStack(spacing: 0) {
                // Restart-required banner: one line per applied update, until
                // the app restarts (restarting IS the remedy — state is in-memory).
                if
                    let updateManager = coordinator.pluginUpdateManager,
                    !updateManager.restartNotices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(updateManager.restartNotices) { notice in
                            Label(restartText(notice), symbol: .exclamationmarkTriangle)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .accessibilityIdentifier("pluginRestartBanner")
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update reminders")
                        Text("Dismissed CtrlX, plugin, and CLI notices reappear after")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(
                        "Dismissed update reminders reappear after",
                        selection: Binding(
                            get: { coordinator.agentUpdateReminderInterval },
                            set: { coordinator.agentUpdateReminderInterval = $0 }
                        )
                    ) {
                        ForEach(AgentUpdateReminderInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityIdentifier("agentUpdateReminderInterval")
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                let agents = coordinator.agentPluginList()

                // Segmented picker at the top
                if agents.count > 1 {
                    Picker("Agent", selection: $selectedAgentID) {
                        ForEach(agents) { agent in
                            Text(agent.name).tag(agent.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("agentPicker")
                    .padding()
                }

                if selectedAgentID.isEmpty {
                    // Not yet loaded — show nothing (task below will set it)
                    Spacer()
                } else {
                    PluginAgentForm(
                        pluginID: selectedAgentID,
                        onRemove: {
                            pluginToRemove = selectedAgentID
                            showRemoveConfirmation = true
                        },
                        onReviewUpdate: { url in
                            addPlugin = .urlPrefilled(url.absoluteString)
                        }
                    )
                    .id(selectedAgentID)
                }

                Divider()

                HStack {
                    Text("Codex & Claude Code CLI").foregroundStyle(.secondary)
                    Spacer()
                    Button(coordinator.agentCLIInstallations?.isPerformingOperation == true ? "View Agent Setup…" : "Agent Setup…") {
                        coordinator.agentCLIInstallations?.dismissStartupPrompt()
                        coordinator.agentCLIInstallations?.refresh()
                        openWindow(id: "agent-cli-setup")
                    }
                    .disabled(coordinator.agentCLIInstallations == nil)
                    .accessibilityIdentifier("agentCLISetupButton")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                // Toolbar row at the bottom of the tab
                HStack {
                    Button {
                        addPlugin = .url
                    } label: {
                        Label("Add Plugin from URL…", symbol: .arrowDownCircle)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("addPluginFromURL")

                    Button {
                        chooseZip()
                    } label: {
                        Label("Install from Zip…", symbol: .docZipper)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("installPluginFromZip")

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 500, minHeight: 400)
            .sheet(item: $addPlugin) { presentation in
                switch presentation {
                case .url:
                    AddPluginSheet()
                case let .zip(url):
                    AddPluginSheet(source: .zip(url))
                case let .urlPrefilled(urlString):
                    AddPluginSheet(initialURLString: urlString)
                }
            }
            .confirmationDialog(
                "Remove Plugin",
                isPresented: $showRemoveConfirmation,
                presenting: pluginToRemove
            ) { id in
                Button("Remove \"\(pluginDisplayName(id))\"", role: .destructive) {
                    Task {
                        await performRemove(id: id)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pluginToRemove = nil
                }
            } message: { id in
                Text("This will uninstall the \"\(pluginDisplayName(id))\" plugin and delete its files. This cannot be undone.")
            }
            .task {
                if let requested = coordinator.agentSettingsSelection {
                    selectedAgentID = requested
                    coordinator.agentSettingsSelection = nil
                }
                // Set initial selection once (only when empty to avoid overwriting
                // a user change that races with the first render).
                if
                    selectedAgentID.isEmpty,
                    let defaultID = AgentLaunchDefaults.selectedID(availableIDs: coordinator.agentPluginList().map(\.id)) {
                    selectedAgentID = defaultID
                }
            }
            // Auto-select a freshly installed plugin in the picker.
            .onChange(of: coordinator.lastInstalledPluginID) { _, newID in
                if let newID {
                    selectedAgentID = newID
                }
            }
            .onChange(of: coordinator.agentSettingsSelection) { _, newID in
                if let newID {
                    selectedAgentID = newID
                    coordinator.agentSettingsSelection = nil
                }
            }
        }

        // MARK: - Helpers

        private func pluginDisplayName(_ id: String) -> String {
            coordinator.agentPluginList().first { $0.id == id }?.name ?? id
        }

        private func restartText(_ notice: PluginRestartNotice) -> String {
            // needsAppRestart == false ⇒ the sidecar was hot-swapped while no
            // sessions were active, so there is nothing to tell the user to
            // restart — just report the update.
            notice.needsAppRestart
                ? "\(notice.displayName) updated to \(notice.newVersion) — restart CtrlX and your \(notice.displayName) sessions"
                : "\(notice.displayName) updated to \(notice.newVersion)"
        }

        /// Present an open panel for a local `.zip` bundle; on selection, trigger
        /// the trust + install sheet for that zip.
        @MainActor
        private func chooseZip() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.zip]
            panel.message = "Select a plugin .zip bundle"
            panel.prompt = "Choose"

            if panel.runModal() == .OK, let url = panel.url {
                addPlugin = .zip(url)
            }
        }

        @MainActor
        private func performRemove(id: String) async {
            _ = await coordinator.removePlugin(id: id, deleteState: true)
            // If the removed plugin was selected, prefer Codex among the remaining agents.
            if selectedAgentID == id {
                selectedAgentID = AgentLaunchDefaults.selectedID(
                    availableIDs: coordinator.agentPluginList().map(\.id).filter { $0 != id }
                ) ?? ""
            }
            pluginToRemove = nil
        }
    }

    // MARK: - AddPluginPresentation

    /// Single source-of-truth for the Add-Plugin `.sheet(item:)`: either the
    /// URL-entry flow or a chosen local `.zip`.
    private enum AddPluginPresentation: Identifiable {
        case url
        case zip(URL)
        case urlPrefilled(String)

        var id: String {
            switch self {
            case .url: "url"
            case let .zip(url): "zip:\(url.path)"
            case let .urlPrefilled(string): "url:\(string)"
            }
        }
    }

    // MARK: - PluginAgentForm

    /// Per-agent settings form. Decodes the correct typed-settings struct (switching
    /// on pluginID), renders shared field UI, and re-encodes + persists on every
    /// change. Config-folder rows appear below with Install/Uninstall actions.
    private struct PluginAgentForm: View {
        let pluginID: String
        /// Invoked when the user taps "Remove Plugin…". The parent owns the
        /// confirmation dialog and selection reset, since removal mutates the
        /// outer `selectedAgentID`.
        let onRemove: () -> Void
        /// Invoked from the source-changed "Review…" button with the plugin's
        /// manifest URL; the parent presents the trust sheet prefilled.
        let onReviewUpdate: (URL) -> Void

        @Environment(AppCoordinator.self) private var coordinator

        // The decoded field values (shared between both concrete types)
        @State private var commandPath = ""
        @State private var autoRun = true
        @State private var logLevel: LogLevel = .info
        @State private var closePaneOnSessionEnd = false
        @State private var additionalConfigFolders: [String] = []
        @State private var providers: [AgentProviderDraft] = []
        @State private var defaultProviderID: String?
        @State private var providerEditor: AgentProviderEditorPresentation?
        // Codex-only: point Codex's OTLP export at the loopback receiver (#602).
        @State private var exportTelemetry = true
        // Claude-only: verify Stop hooks with Apple Intelligence (#644).
        @State private var detectFalseStops = true
        /// Whether the "what does this do?" popover for the completion-check
        /// toggle is showing.
        @State private var showDetectFalseStopsInfo = false
        /// Whether the on-device model can actually classify on this Mac —
        /// probed on load so the toggle renders its real state (disabled +
        /// caption when the check would be inert) instead of a live-looking
        /// switch that silently does nothing.
        @State private var detectFalseStopsAvailability: StopFinalityAvailability = .available

        @Dependency(StopFinalityClassifier.self) private var stopFinalityClassifier
        @Dependency(SecretsService.self) private var secrets

        /// Whether the agent binary was not found
        @State private var agentUnavailable = false

        /// Inline write error
        @State private var writeError: String?

        /// Prevent persisting while we're still loading
        @State private var isLoaded = false

        var body: some View {
            Form {
                // Agent-unavailable banner
                if agentUnavailable {
                    Section {
                        Label(
                            "\(agentDisplayName) CLI not found — install it to enable this agent.",
                            symbol: .exclamationmarkTriangle
                        )
                        .foregroundStyle(.orange)
                    }
                }

                // Inline write-error banner
                if let writeError {
                    Section {
                        Label(writeError, symbol: .exclamationmarkCircleFill)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("agentWriteError-\(pluginID)")
                    }
                }

                // Command + Browse
                Section("Command") {
                    HStack {
                        TextField("Command path", text: $commandPath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { persist() }
                            .accessibilityIdentifier("agentCommandPath-\(pluginID)")
                        Button("Browse…") {
                            browseForCommand()
                        }
                    }
                }

                if let agent = InstallableAgentCLI(rawValue: pluginID) {
                    AgentCLIUpdateSection(agent: agent)
                }

                // Behaviour
                Section("Behaviour") {
                    Toggle("Auto-run \(agentDisplayName) in project folders", isOn: $autoRun)
                        .onChange(of: autoRun) { _, _ in persist() }
                        .accessibilityIdentifier("agentAutoRun-\(pluginID)")

                    Picker("Log level", selection: $logLevel) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            Text(level.rawValue.capitalized).tag(level)
                        }
                    }
                    .onChange(of: logLevel) { _, _ in persist() }
                    .accessibilityIdentifier("agentLogLevel-\(pluginID)")

                    Toggle("Close session when \(agentDisplayName) exits", isOn: $closePaneOnSessionEnd)
                        .onChange(of: closePaneOnSessionEnd) { _, _ in persist() }
                        .accessibilityIdentifier("agentClosePane-\(pluginID)")

                    // Claude-only: Claude can fire a Stop hook while a background
                    // task or cron is still pending. When on, on-device Apple
                    // Intelligence judges whether the last message really reads as
                    // finished, and keeps the session "working" if it doesn't (#644).
                    // The ⓘ button (right of the label, not the switch) opens a
                    // popover with the full explanation; the hover tooltip carries
                    // the same copy for mouse users. Explicit row layout — text +
                    // button siblings, switch pushed trailing via `labelsHidden` —
                    // so the button's clicks can't be swallowed by a toggle label.
                    if pluginID == "claude-code" {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("Verify completion with Apple Intelligence")
                                    .foregroundStyle(detectFalseStopsAvailability.disablesToggle ? .secondary : .primary)
                                Button {
                                    showDetectFalseStopsInfo = true
                                } label: {
                                    Symbols.infoCircle.image
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("About completion verification")
                                .accessibilityIdentifier("agentDetectFalseStopsInfo-\(pluginID)")
                                .popover(isPresented: $showDetectFalseStopsInfo, arrowEdge: .bottom) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Verify completion with Apple Intelligence")
                                            .font(.headline)
                                        Text(detectFalseStopsHelp)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(16)
                                    .frame(width: 340)
                                }
                                Spacer()
                                Toggle("Verify completion with Apple Intelligence", isOn: $detectFalseStops)
                                    .labelsHidden()
                                    .disabled(detectFalseStopsAvailability.disablesToggle)
                                    .onChange(of: detectFalseStops) { _, _ in persist() }
                                    .accessibilityIdentifier("agentDetectFalseStops-\(pluginID)")
                                    .help(detectFalseStopsHelp)
                            }
                            // Why the check is inert on this Mac (pre-26 OS, Apple
                            // Intelligence off, model downloading). The ⓘ popover
                            // stays clickable so the explanation is reachable even
                            // when the toggle is disabled.
                            if let caption = detectFalseStopsAvailability.settingsCaption {
                                Text(caption)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("agentDetectFalseStopsCaption-\(pluginID)")
                            }
                        }
                    }

                    // Codex configures OTEL through its own config (it doesn't read
                    // `OTEL_*` env vars like Claude), so the export is opt-out-able
                    // per-agent here (#602). Claude has no equivalent toggle.
                    if pluginID == "codex" {
                        Toggle("Export telemetry (tokens, latency, model)", isOn: $exportTelemetry)
                            .onChange(of: exportTelemetry) { _, _ in persist() }
                            .accessibilityIdentifier("agentExportTelemetry-\(pluginID)")
                            .help(
                                "Point this agent's OpenTelemetry export at CtrlX's loopback receiver "
                                    + "so the session's token meter, latency, and model show in the UI. "
                                    + "One-way and local only — no prompt or tool content leaves your Mac."
                            )
                    }
                }

                // Updates (URL-installed plugins only — bundled and
                // folder-dropped plugins have no update source)
                if
                    let updateManager = coordinator.pluginUpdateManager,
                    updateManager.isUpdatable(pluginID) {
                    Section("Updates") {
                        Toggle(
                            "Check for updates automatically",
                            isOn: Binding(
                                get: { updateManager.autoUpdateEnabled(pluginID) },
                                set: { updateManager.setAutoUpdate(pluginID, enabled: $0) }
                            )
                        )
                        .accessibilityIdentifier("agentAutoUpdate-\(pluginID)")

                        HStack(spacing: 8) {
                            Button("Check Now") {
                                updateManager.checkNow(pluginID)
                            }
                            .disabled(updateManager.inlineStatus[pluginID] == .checking)
                            .accessibilityIdentifier("agentCheckUpdates-\(pluginID)")

                            if updateManager.inlineStatus[pluginID] == .checking {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Spacer()

                            if let lastCheck = updateManager.lastCheckDate {
                                Text("Last checked \(lastCheck, format: .relative(presentation: .named))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        updateStatusRow(updateManager)
                    }
                }

                // Config folders
                if pluginID == CodexPluginCore.pluginID || pluginID == ClaudeCodePluginCore.pluginID {
                    providerSettingsSection
                }

                // Config folders
                Section {
                    // Default root row (not removable)
                    configFolderRow(path: defaultConfigRoot, removable: false)

                    // Additional folders
                    ForEach(additionalConfigFolders, id: \.self) { folder in
                        configFolderRow(path: folder, removable: true)
                    }

                    Button("Add Folder…") {
                        addConfigFolder()
                    }
                    .accessibilityIdentifier("agentAddFolder-\(pluginID)")
                } header: {
                    // The explanation lives beside the title rather than in a
                    // section footer: the Agents window's bottom toolbar
                    // (Add Plugin from URL / Install from Zip) can occlude the
                    // last section's footer, so a footer here would be unseen.
                    HStack(alignment: .firstTextBaseline) {
                        Text("Config Folders")
                        Spacer(minLength: 12)
                        Text("Additional folders where the \(agentDisplayName) plugin should be installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // Remove plugin (only for non-bundled, folder-dropped/URL plugins)
                if !coordinator.isBundledPlugin(id: pluginID) {
                    Section {
                        Button(role: .destructive) {
                            onRemove()
                        } label: {
                            Label("Remove Plugin…", symbol: .minusCircleFill)
                                .foregroundStyle(.red)
                        }
                        .accessibilityIdentifier("removePlugin-\(pluginID)")
                    } footer: {
                        Text("Uninstall the \(agentDisplayName) plugin and delete its files. This cannot be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            // Load settings whenever the selected plugin changes
            .task(id: pluginID) {
                await loadSettings()
            }
            .onChange(of: coordinator.agentCLIInstallations?.commandRevision) {
                guard isLoaded, let agent = InstallableAgentCLI(rawValue: pluginID) else { return }
                if commandPath == agent.command {
                    let data = coordinator.pluginSettingsData(id: pluginID)
                    let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    commandPath = settings?["command_path"] as? String ?? commandPath
                }
                if case .available = coordinator.agentCLIInstallations?.entries[agent]?.availability {
                    agentUnavailable = false
                }
            }
            .sheet(item: $providerEditor) { presentation in
                AgentProviderEditorSheet(
                    presentation: presentation,
                    onSave: { draft in saveProvider(draft) }
                )
            }
        }

        // MARK: - Computed helpers

        private var providerSettingsSection: some View {
            Section {
                Picker("Default Provider", selection: $defaultProviderID) {
                    Text("Current CLI configuration").tag(String?.none)
                    Text(builtInProviderName).tag(Optional(builtInProviderID))
                    ForEach(providers) { provider in
                        Text(provider.name.isEmpty ? "Unnamed Provider" : provider.name)
                            .tag(Optional(provider.providerID))
                    }
                }
                .onChange(of: defaultProviderID) { persist() }
                .accessibilityIdentifier("agentDefaultProvider-\(pluginID)")

                LabeledContent("Built in", value: builtInProviderName)

                ForEach(providers) { provider in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name.isEmpty ? "Unnamed Provider" : provider.name)
                            Text(provider.baseURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !providerSummary(provider).isEmpty {
                                Text(providerSummary(provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Edit") {
                            providerEditor = AgentProviderEditorPresentation(
                                pluginID: pluginID,
                                original: provider,
                                providers: providerOptions
                            )
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            deleteProvider(provider)
                        } label: {
                            Symbols.minusCircleFill.image
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(provider.name)")
                    }
                }

                Button("Add Provider…") {
                    providerEditor = AgentProviderEditorPresentation(
                        pluginID: pluginID,
                        original: nil,
                        providers: providerOptions
                    )
                }
                .accessibilityIdentifier("agentAddProvider-\(pluginID)")
            } header: {
                Text("Providers")
            } footer: {
                Text("Provider settings stay on this Host. API keys are stored in Keychain and never included in settings, synchronized state, or recovery snapshots.")
                    .font(.caption)
            }
        }

        private var builtInProviderID: String {
            pluginID == CodexPluginCore.pluginID
                ? CodexSettings.builtInProviderID
                : ClaudeCodeSettings.builtInProviderID
        }

        private var builtInProviderName: String {
            pluginID == CodexPluginCore.pluginID
                ? CodexSettings.builtInProvider.name
                : ClaudeCodeSettings.builtInProvider.name
        }

        private var providerOptions: [AgentProviderOption] {
            [AgentProviderOption(id: builtInProviderID, name: builtInProviderName)]
                + providers.map { AgentProviderOption(id: $0.providerID, name: $0.name) }
        }

        private func providerSummary(_ provider: AgentProviderDraft) -> String {
            let effort = pluginID == ClaudeCodePluginCore.pluginID
                ? provider.claudeReasoningEffort?.displayName
                : provider.reasoningEffort?.displayName
            let contextWindow = pluginID == ClaudeCodePluginCore.pluginID
                ? provider.contextWindowTokens.map { "\($0) tokens" }
                : nil
            return [provider.model, effort, contextWindow]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " · ")
        }

        private func saveProvider(_ draft: AgentProviderDraft) {
            if let index = providers.firstIndex(where: { $0.providerID == draft.providerID }) {
                providers[index] = draft
            } else {
                providers.append(draft)
            }
            persist()
        }

        private func deleteProvider(_ provider: AgentProviderDraft) {
            providers.removeAll { $0.providerID == provider.providerID }
            if defaultProviderID == provider.providerID {
                defaultProviderID = nil
            }
            let account = AgentProviderKeychainAccount.account(pluginID: pluginID, providerID: provider.providerID)
            Task {
                do { try await secrets.deleteSecret(account) }
                catch { writeError = "The Provider credential could not be removed from Keychain: \(error.localizedDescription)" }
            }
            persist()
        }

        @ViewBuilder
        private func configFolderRow(path: String, removable: Bool) -> some View {
            let remove: (() -> Void)? = removable ? {
                additionalConfigFolders.removeAll { $0 == path }
                persist()
            } : nil
            if pluginID == "codex" || pluginID == "claude-code", let installations = coordinator.agentPluginInstallations {
                BundledAgentPluginRow(
                    installations: installations,
                    location: AgentPluginLocation(pluginID: pluginID, configRoot: removable ? path : nil),
                    folderPath: path, agentName: agentDisplayName, onRemove: remove
                )
                .id(coordinator.agentCLIInstallations?.commandRevision ?? 0)
            } else {
                AgentConfigFolderRow(pluginID: pluginID, folderPath: path, isRemovable: removable, onRemove: remove)
            }
        }

        private var agentDisplayName: String {
            coordinator.agentPluginList().first { $0.id == pluginID }?.name ?? pluginID
        }

        @ViewBuilder
        private func updateStatusRow(_ updateManager: PluginUpdateManager) -> some View {
            switch updateManager.inlineStatus[pluginID] {
            case .upToDate:
                Text("Up to date")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case let .updated(version, needsAppRestart):
                Text(
                    needsAppRestart
                        ? "Updated to \(version) — restart CtrlX and your \(agentDisplayName) sessions"
                        : "Updated to \(version)"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case let .updateAvailableNewSource(version):
                HStack(spacing: 8) {
                    Label(
                        "Update \(version) is served from a new source",
                        symbol: .exclamationmarkTriangle
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Button("Review…") {
                        if let url = updateManager.manifestURL(pluginID) {
                            onReviewUpdate(url)
                        }
                    }
                    .accessibilityIdentifier("agentReviewUpdate-\(pluginID)")
                }
                .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case let .failed(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("agentUpdateStatus-\(pluginID)")
            case .checking,
                 nil:
                EmptyView()
            }
        }

        /// Help text for the Apple-Intelligence completion-check toggle. Built
        /// here (not inline) so the `Form` body stays within the type-checker's
        /// reach.
        private var detectFalseStopsHelp: String {
            "When \(agentDisplayName) stops while a background task or cron is still "
                + "pending, use on-device Apple Intelligence to check whether the last "
                + "message really reads as finished. If it doesn't, the session stays "
                + "marked as working and the summary arrives as a \"Still Working\" "
                + "notification instead of a done one. Runs entirely on your Mac. "
                + "Requires Apple Intelligence (macOS 26+); otherwise ignored."
        }

        private var defaultConfigRoot: String {
            switch pluginID {
            case "claude-code": return "~/.claude"
            case "codex": return "~/.codex"
            // A sidecar declares its own default root in the manifest
            // (`sidecar.default_config_root`); fall back to `~` when absent.
            default: return coordinator.pluginDefaultConfigRoot(id: pluginID) ?? "~"
            }
        }

        // MARK: - Load

        @MainActor
        private func loadSettings() async {
            isLoaded = false
            writeError = nil

            let data = coordinator.pluginSettingsData(id: pluginID)
            switch pluginID {
            case "claude-code":
                let s = ClaudeCodeSettings.decode(from: data)
                commandPath = s.commandPath
                autoRun = s.autoRun
                logLevel = s.logLevel
                closePaneOnSessionEnd = s.closePaneOnSessionEnd
                additionalConfigFolders = s.additionalConfigFolders
                exportTelemetry = true
                detectFalseStops = s.detectFalseStops
                providers = s.providers.map { AgentProviderDraft(profile: $0, pluginID: pluginID) }
                defaultProviderID = s.resolvedDefaultProviderID
                detectFalseStopsAvailability = stopFinalityClassifier.availability()
            case "codex":
                let s = CodexSettings.decode(from: data)
                commandPath = s.commandPath
                autoRun = s.autoRun
                logLevel = s.logLevel
                closePaneOnSessionEnd = s.closePaneOnSessionEnd
                additionalConfigFolders = s.additionalConfigFolders
                exportTelemetry = s.exportTelemetry
                detectFalseStops = true
                providers = s.providers.map { AgentProviderDraft(profile: $0, pluginID: pluginID) }
                defaultProviderID = s.resolvedDefaultProviderID
            default:
                // Any non-bundled sidecar: generic settings that persist + reach
                // the sidecar via apply_settings.
                let s = SidecarPluginSettings.decode(from: data)
                commandPath = s.commandPath
                autoRun = s.autoRun
                logLevel = s.logLevel
                closePaneOnSessionEnd = s.closePaneOnSessionEnd
                additionalConfigFolders = s.additionalConfigFolders
                exportTelemetry = true
                detectFalseStops = true
                providers = []
                defaultProviderID = nil
            }

            // Check agent availability for the default root
            let loadedCommand = commandPath
            let status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: nil)
            agentUnavailable = (status == .agentUnavailable)
            // CLI setup may finish while the plugin check is suspended. Preserve typed drafts,
            // but don't let the next toggle save the pre-install command back over the new path.
            if let agent = InstallableAgentCLI(rawValue: pluginID), commandPath == loadedCommand {
                commandPath = AgentCLICommandSettings.command(in: coordinator.pluginSettingsData(id: pluginID), agent: agent)
                if case let .available(path, _, _) = coordinator.agentCLIInstallations?.entries[agent]?.availability, path == commandPath {
                    agentUnavailable = false
                }
            }

            isLoaded = true
        }

        // MARK: - Persist

        private func persist() {
            guard isLoaded else { return }
            let data = encodeSettings()
            let id = pluginID
            Task {
                let error = await coordinator.setPluginSettings(id: id, data)
                guard pluginID == id else { return }
                writeError = error
            }
        }

        private func encodeSettings() -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            switch pluginID {
            case "claude-code":
                let s = ClaudeCodeSettings(
                    commandPath: commandPath,
                    autoRun: autoRun,
                    logLevel: logLevel,
                    additionalConfigFolders: additionalConfigFolders,
                    closePaneOnSessionEnd: closePaneOnSessionEnd,
                    detectFalseStops: detectFalseStops,
                    providers: providers.map { $0.claudeProfile() },
                    defaultProviderID: defaultProviderID
                )
                return (try? encoder.encode(s)) ?? Data()
            case "codex":
                let s = CodexSettings(
                    commandPath: commandPath,
                    autoRun: autoRun,
                    logLevel: logLevel,
                    closePaneOnSessionEnd: closePaneOnSessionEnd,
                    additionalConfigFolders: additionalConfigFolders,
                    exportTelemetry: exportTelemetry,
                    providers: providers.map { $0.codexProfile() },
                    defaultProviderID: defaultProviderID
                )
                return (try? encoder.encode(s)) ?? Data()
            default:
                let s = SidecarPluginSettings(
                    commandPath: commandPath,
                    autoRun: autoRun,
                    logLevel: logLevel,
                    additionalConfigFolders: additionalConfigFolders,
                    closePaneOnSessionEnd: closePaneOnSessionEnd
                )
                return (try? encoder.encode(s)) ?? Data()
            }
        }

        // MARK: - Browse

        @MainActor
        private func browseForCommand() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
            panel.message = "Select the \(agentDisplayName) executable"

            if panel.runModal() == .OK, let url = panel.url {
                commandPath = url.path
                persist()
            }
        }

        @MainActor
        private func addConfigFolder() {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            panel.message = "Select an additional config folder for \(agentDisplayName)"
            panel.prompt = "Add Folder"

            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = url.standardizedFileURL.path
            guard !additionalConfigFolders.contains(path) else { return }
            additionalConfigFolders.append(path)
            persist()
        }
    }

    // MARK: - Provider editing

    struct AgentProviderDraft: Identifiable, Equatable {
        let providerID: String
        var name: String
        var baseURL: String
        var model: String
        var environmentKey: String
        var authKind: ClaudeProviderAuthKind
        var reasoningEffort: CodexReasoningEffort?
        var claudeReasoningEffort: ClaudeReasoningEffort?
        var contextWindowTokens: Int?

        var id: String {
            providerID
        }

        init(pluginID: String) {
            self.providerID = UUID().uuidString.lowercased()
            self.name = ""
            self.baseURL = ""
            self.model = ""
            self.reasoningEffort = nil
            self.claudeReasoningEffort = nil
            self.contextWindowTokens = nil
            if pluginID == CodexPluginCore.pluginID {
                self.environmentKey = "OPENAI_API_KEY"
                self.authKind = .apiKey
            } else {
                self.environmentKey = ClaudeProviderAuthKind.authToken.environmentKey
                self.authKind = .authToken
            }
        }

        init(profile: CodexProviderProfile, pluginID _: String) {
            self.providerID = profile.id
            self.name = profile.name
            self.baseURL = profile.baseURL
            self.model = profile.model
            self.environmentKey = profile.environmentKey
            self.authKind = .apiKey
            self.reasoningEffort = profile.reasoningEffort
            self.claudeReasoningEffort = nil
            self.contextWindowTokens = nil
        }

        init(profile: ClaudeProviderProfile, pluginID _: String) {
            self.providerID = profile.id
            self.name = profile.name
            self.baseURL = profile.baseURL
            self.model = profile.model
            self.environmentKey = profile.environmentKey
            self.authKind = profile.authKind
            self.reasoningEffort = nil
            self.claudeReasoningEffort = profile.reasoningEffort
            self.contextWindowTokens = profile.contextWindowTokens
        }

        func codexProfile() -> CodexProviderProfile {
            CodexProviderProfile(
                id: providerID,
                name: name,
                baseURL: baseURL,
                model: model,
                environmentKey: environmentKey,
                reasoningEffort: reasoningEffort
            )
        }

        func claudeProfile() -> ClaudeProviderProfile {
            ClaudeProviderProfile(
                id: providerID,
                name: name,
                baseURL: baseURL,
                model: model,
                authKind: authKind,
                environmentKey: authKind.environmentKey,
                reasoningEffort: claudeReasoningEffort,
                contextWindowTokens: contextWindowTokens
            )
        }
    }

    struct AgentProviderEditorPresentation: Identifiable {
        let id = UUID()
        let pluginID: String
        let original: AgentProviderDraft?
        let providers: [AgentProviderOption]

        func nameValidationError(for draft: AgentProviderDraft) -> String? {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "Enter a Provider name." }
            // Existing duplicate names must not block connection-only edits.
            if let original, name.caseInsensitiveCompare(original.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame {
                return nil
            }
            if
                providers.contains(where: {
                    $0.id != draft.providerID
                        && name.caseInsensitiveCompare($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                }) {
                return "A Provider with this name already exists. Choose a different name."
            }
            return nil
        }
    }

    struct AgentProviderEditorSheet: View {
        let presentation: AgentProviderEditorPresentation
        let onSave: (AgentProviderDraft) -> Void

        @Environment(\.dismiss) private var dismiss
        @Dependency(SecretsService.self) private var secrets

        @State private var draft: AgentProviderDraft
        @State private var contextWindowTokensText: String
        @State private var apiKey = ""
        @State private var isAPIKeyVisible = false
        @State private var hasStoredKey = false
        @State private var isLoadingKey = false
        @State private var isSaving = false
        @State private var errorMessage: String?

        init(presentation: AgentProviderEditorPresentation, onSave: @escaping (AgentProviderDraft) -> Void) {
            self.presentation = presentation
            self.onSave = onSave
            let original = presentation.original ?? AgentProviderDraft(pluginID: presentation.pluginID)
            _draft = State(initialValue: original)
            _contextWindowTokensText = State(initialValue: original.contextWindowTokens.map(String.init) ?? "")
        }

        private var isNew: Bool {
            presentation.original == nil
        }

        private var isClaude: Bool {
            presentation.pluginID == ClaudeCodePluginCore.pluginID
        }

        var body: some View {
            Form {
                Section("Provider") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("agentProviderName")
                }

                Section("Connection") {
                    TextField("Base URL", text: $draft.baseURL, prompt: Text("https://api.example.com"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("agentProviderBaseURL")
                    TextField("Model", text: $draft.model)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("agentProviderModel")
                    if isClaude {
                        Picker("Default reasoning effort", selection: $draft.claudeReasoningEffort) {
                            Text("Use Claude Code default").tag(ClaudeReasoningEffort?.none)
                            ForEach(ClaudeReasoningEffort.allCases) { effort in
                                Text(effort.displayName).tag(Optional(effort))
                            }
                        }
                        .accessibilityIdentifier("agentProviderClaudeReasoningEffort")
                        Text("Passed as --effort to new sessions and forks that target this Provider. Leave it at the Claude Code default unless the Provider supports Claude's effort levels.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Context window (tokens)", text: $contextWindowTokensText, prompt: Text("e.g. 1000000"))
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("agentProviderContextWindowTokens")
                        Text("Optional. Declares the model's real context window through CLAUDE_CODE_MAX_CONTEXT_TOKENS. Set this for custom models Claude Code does not recognize to remove its 200K-window warning.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Reasoning effort", selection: $draft.reasoningEffort) {
                            Text("Use Codex configuration").tag(CodexReasoningEffort?.none)
                            ForEach(CodexReasoningEffort.allCases) { effort in
                                Text(effort.displayName).tag(Optional(effort))
                            }
                        }
                        .accessibilityIdentifier("agentProviderReasoningEffort")
                        Text("Overrides model_reasoning_effort for this Provider. Custom Providers also expose this model and all reasoning levels to Codex's /model command. Leave it at the Codex configuration default unless the endpoint supports reasoning effort.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Authentication") {
                    if isClaude {
                        Picker("Credential", selection: $draft.authKind) {
                            Text("API key (x-api-key)").tag(ClaudeProviderAuthKind.apiKey)
                            Text("Auth token (Bearer)").tag(ClaudeProviderAuthKind.authToken)
                        }
                        .onChange(of: draft.authKind) { draft.environmentKey = draft.authKind.environmentKey }
                        LabeledContent("Environment variable", value: draft.authKind.environmentKey)
                    } else {
                        TextField("Environment variable", text: $draft.environmentKey)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("agentProviderEnvironmentKey")
                    }
                    HStack {
                        Group {
                            if isAPIKeyVisible {
                                TextField(apiKeyPrompt, text: $apiKey)
                            } else {
                                SecureField(apiKeyPrompt, text: $apiKey)
                            }
                        }
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .privacySensitive()
                        .accessibilityIdentifier("agentProviderAPIKey")

                        Button {
                            isAPIKeyVisible.toggle()
                        } label: {
                            Label(
                                isAPIKeyVisible ? "Hide API Key" : "Show API Key",
                                symbol: isAPIKeyVisible ? .eyeSlash : .eye
                            )
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help(isAPIKeyVisible ? "Hide API Key" : "Show API Key")
                        .accessibilityIdentifier("agentProviderAPIKeyVisibility")
                    }
                    if hasStoredKey {
                        Text("A key is stored in Keychain. Enter a new value only to replace it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Stored in Keychain on this Host; never written to settings or sent to Viewers.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { dismiss() }
                            .disabled(isSaving)
                        Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSaving || isLoadingKey)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 520, height: 560)
            .task {
                guard let original = presentation.original else { return }
                isLoadingKey = true
                defer { isLoadingKey = false }
                let account = AgentProviderKeychainAccount.account(
                    pluginID: presentation.pluginID,
                    providerID: original.providerID
                )
                do {
                    apiKey = try await secrets.loadSecret(account) ?? ""
                    hasStoredKey = !apiKey.isEmpty
                } catch {
                    errorMessage = "The stored API key could not be read from Keychain."
                }
            }
        }

        private var apiKeyPrompt: String {
            hasStoredKey && !isNew ? "API key (leave blank to keep stored key)" : "API key"
        }

        private func save() async {
            guard !isSaving else { return }
            errorMessage = nil
            let providerID = draft.providerID
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextWindowTokens: Int?
            if isClaude {
                let value = contextWindowTokensText.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    contextWindowTokens = nil
                } else if let tokens = Int(value), ClaudeCodeSettings.isValidContextWindowTokens(tokens) {
                    contextWindowTokens = tokens
                } else {
                    errorMessage = "Enter a context window between 1 and 10,000,000 tokens, or leave it blank."
                    return
                }
            } else {
                contextWindowTokens = nil
            }
            let environmentKey = isClaude
                ? draft.authKind.environmentKey
                : draft.environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)

            if let error = presentation.nameValidationError(for: draft) {
                errorMessage = error
                return
            }
            guard
                let url = URL(string: baseURL), url.scheme == "http" || url.scheme == "https", url.host != nil
            else {
                errorMessage = "Enter an absolute http:// or https:// Base URL."
                return
            }
            guard !model.isEmpty else {
                errorMessage = "Enter the model name used by this Provider."
                return
            }
            let environmentKeyIsValid = isClaude
                ? ClaudeCodeSettings.isValidEnvironmentKey(environmentKey)
                : CodexSettings.isValidEnvironmentKey(environmentKey)
            guard environmentKeyIsValid else {
                errorMessage = "Enter a valid environment variable name."
                return
            }
            guard !apiKey.isEmpty || hasStoredKey else {
                errorMessage = "Enter the API key for this Provider."
                return
            }

            isSaving = true
            defer { isSaving = false }
            let account = AgentProviderKeychainAccount.account(
                pluginID: presentation.pluginID,
                providerID: providerID
            )
            do {
                if !apiKey.isEmpty {
                    try await secrets.storeSecret(apiKey, account)
                }
            } catch {
                errorMessage = "The API key could not be stored in Keychain: \(error.localizedDescription)"
                return
            }

            draft.name = name
            draft.baseURL = baseURL
            draft.model = model
            draft.environmentKey = environmentKey
            draft.contextWindowTokens = contextWindowTokens
            onSave(draft)
            dismiss()
        }
    }

    // MARK: - AgentConfigFolderRow

    /// A row in the config-folders list. Owns its install-status state and drives
    /// Install/Uninstall actions through `AppCoordinator`.
    ///
    /// - `configRoot: nil` → the default root row (not removable).
    /// - `configRoot: path` → an additional folder row (removable).
    private struct AgentConfigFolderRow: View {
        let pluginID: String
        /// The display path shown to the user (e.g. "~/.claude" or the actual path).
        let folderPath: String
        let isRemovable: Bool
        let onRemove: (() -> Void)?

        @Environment(AppCoordinator.self) private var coordinator

        @State private var status: PluginInstallStatus = .notInstalled
        @State private var busy = false
        @State private var error: String?

        /// `nil` for the default root, absolute path for additional folders.
        private var configRootArg: String? {
            // Default root rows use folderPath like "~/.claude" — these pass nil
            // (the coordinator resolves the default). Additional-folder rows pass
            // the real absolute path.
            isRemovable ? folderPath : nil
        }

        /// Stable identifier suffix for this row's controls. The default root row
        /// uses "default"; additional folders use their config-root path so each
        /// row's Install/Uninstall button is uniquely addressable.
        private var rowKey: String {
            configRootArg ?? "default"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Path label
                    Text(abbreviatedPath(folderPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folderPath)

                    Spacer()

                    // Status + action area
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        statusAndAction
                    }

                    // Remove button for non-default rows
                    if isRemovable {
                        Button {
                            onRemove?()
                        } label: {
                            Symbols.minusCircleFill.image
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this folder")
                    }
                }

                // Inline error below the row (sibling, not an overlay).
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier("installStatus-\(pluginID)-\(rowKey)")
            .task(id: folderPath) {
                await refreshStatus()
            }
        }

        @ViewBuilder
        private var statusAndAction: some View {
            switch status {
            case let .installed(version):
                HStack(spacing: 6) {
                    Label(
                        version.map { "Installed v\($0)" } ?? "Installed",
                        symbol: .checkmarkCircleFill
                    )
                    .font(.caption)
                    .foregroundStyle(.green)

                    if pluginID == "codex" {
                        Button("Refresh") {
                            Task { await performInstall() }
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("refreshPlugin-\(pluginID)-\(rowKey)")
                        .help("Update CtrlX skills for this configuration. Start a new Codex session to use them.")
                    }

                    Button("Uninstall") {
                        Task { await performUninstall() }
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("uninstallPlugin-\(pluginID)-\(rowKey)")
                }

            case .notInstalled:
                Button("Install") {
                    Task { await performInstall() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("installPlugin-\(pluginID)-\(rowKey)")

            case .agentUnavailable:
                Label("Agent not found", symbol: .exclamationmarkTriangle)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Install the \(pluginID) CLI to enable plugin installation for this folder")
                    .disabled(true)

            case let .checkFailed(message):
                Text("Check failed: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") { Task { await refreshStatus() } }
            }
        }

        // MARK: - Actions

        @MainActor
        private func refreshStatus() async {
            status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: configRootArg)
        }

        @MainActor
        private func performInstall() async {
            busy = true
            error = nil
            let result = await coordinator.installPlugin(id: pluginID, configRoot: configRootArg)
            error = result
            status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: configRootArg)
            busy = false
        }

        @MainActor
        private func performUninstall() async {
            busy = true
            error = nil
            let result = await coordinator.uninstallPlugin(id: pluginID, configRoot: configRootArg)
            error = result
            status = await coordinator.pluginInstallStatus(id: pluginID, configRoot: configRootArg)
            busy = false
        }

        // MARK: - Helpers

        private func abbreviatedPath(_ path: String) -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if path.hasPrefix(home + "/") || path == home {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }
    }
#endif
