#if os(macOS)
    import AppKit
    import CtrlxCommon
    import SwiftUI

    public struct AgentCLIInstallationView: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.dismiss) private var dismiss
        @Environment(\.openWindow) private var openWindow

        public init() { }

        public var body: some View {
            Group {
                if let installations = coordinator.agentCLIInstallations {
                    AgentCLIInstallationContent(installations: installations, close: { dismiss() }, launch: { agent in
                        coordinator.pendingAgentCLILaunch = agent.id
                        openWindow(id: "panes")
                        dismiss()
                    })
                } else {
                    ProgressView("Preparing Agent setup…")
                }
            }
            .frame(minWidth: 540, minHeight: 420)
        }
    }

    struct AgentCLIUpdateBanner: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(AppSettings.self) private var settings
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            if let installations = coordinator.agentCLIInstallations, let update = installations.updates.first {
                HStack {
                    Label(
                        "A newer \(update.agent.name) CLI is available: v\(update.latestVersion) (installed v\(update.installedVersion)).",
                        symbol: .infoCircle
                    )
                    Spacer()
                    Button("Review in Settings…") {
                        coordinator.agentSettingsSelection = update.agent.id
                        settings.selectedSettingsTab = .agents
                        openSettings()
                        installations.dismiss(update)
                    }
                    Button("Dismiss") { installations.dismiss(update) }
                }
                .font(.callout)
                .padding(10)
                .background(.bar)
                .accessibilityIdentifier("agentCLIUpdateBanner")
            }
        }
    }

    struct AgentCLIUpdateSection: View {
        let agent: InstallableAgentCLI
        @Environment(AppCoordinator.self) private var coordinator

        var body: some View {
            if let installations = coordinator.agentCLIInstallations {
                let entry = installations.entries[agent] ?? .init()
                Section("CLI Update") {
                    LabeledContent("Installed", value: installedVersion(entry))
                    LabeledContent("Latest", value: entry.latestVersion ?? "Not checked")

                    HStack(spacing: 8) {
                        Button("Check Now") { installations.refresh(agent) }
                            .disabled(installations.isBusy)
                            .accessibilityIdentifier("agentCLICheckUpdate-\(agent.id)")

                        if installations.isBusy {
                            ProgressView().controlSize(.small)
                        }

                        Spacer()

                        if entry.updateAvailable {
                            Button("Update") { installations.maintain(agent, action: .update) }
                                .disabled(installations.isBusy || entry.managedInstallation == nil)
                                .accessibilityIdentifier("agentCLIUpdate-\(agent.id)")
                        } else if entry.latestVersion != nil, entry.installedVersion != nil {
                            Label("Up to date", symbol: .checkmarkCircle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let checked = entry.latestCheckedAt {
                            Text("Checked \(checked, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if entry.updateAvailable, entry.managedInstallation == nil {
                        Text("Manage this update with the installation's original installer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entry.updateErrorMessages, id: \.self) { error in
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        private func installedVersion(_ entry: AgentCLIInstallation) -> String {
            if let version = entry.installedVersion {
                return version
            }
            switch entry.availability {
            case .missing: return "Not installed"
            case .unavailable: return "Unavailable"
            default: return "Checking…"
            }
        }
    }

    struct AgentCLIInstallationContent: View {
        @Bindable var installations: AgentCLIInstallations
        let close: () -> Void
        let launch: (InstallableAgentCLI) -> Void
        @State private var selected = Set(InstallableAgentCLI.allCases)
        @State private var showsLog = false

        private var log: String {
            InstallableAgentCLI.allCases.compactMap { agent in
                guard let text = installations.entries[agent]?.log, !text.isEmpty else { return nil }
                return "\(agent.name)\n\(text)"
            }.joined(separator: "\n\n")
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Agent Setup").font(.title2.bold())
                Text("Install, update, or repair agents on this Mac. Sign in when you first open an agent.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(InstallableAgentCLI.allCases) { agent in
                            agentRow(agent)
                        }
                        Toggle("Remind me at startup when an agent is missing", isOn: $installations.remindAtStartup)
                            .accessibilityIdentifier("agentCLIReminder")
                        DisclosureGroup("Activity log", isExpanded: $showsLog) {
                            ScrollView {
                                Text(log.isEmpty ? "No output yet." : log)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 140)
                            Button("Copy Log") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(log, forType: .string)
                            }
                            .disabled(log.isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if installations.isPerformingOperation {
                        Button("Cancel") { installations.cancel() }
                            .accessibilityIdentifier("agentCLICancel")
                    } else {
                        Button("Check Again") { installations.refresh() }.disabled(installations.isBusy)
                    }
                    Spacer()
                    Button(installations.isPerformingOperation ? "Continue in Background" : installations.missing.isEmpty ? "Done" : "Later") { close() }
                    if !installations.missing.isEmpty {
                        Button("Install Selected") {
                            installations.install(selected)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installations.isBusy || selected.isDisjoint(with: installations.missing))
                        .accessibilityIdentifier("agentCLIInstallSelected")
                    }
                }
            }
            .padding(24)
            .onAppear { installations.dismissStartupPrompt() }
            .onChange(of: installations.isPerformingOperation, initial: true) {
                if installations.isPerformingOperation {
                    showsLog = true
                }
            }
            .accessibilityIdentifier("agentCLISetup")
        }

        private func agentRow(_ agent: InstallableAgentCLI) -> some View {
            let entry = installations.entries[agent] ?? .init()
            return VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if entry.availability == .missing {
                        Toggle(agent.name, isOn: Binding(
                            get: { selected.contains(agent) },
                            set: {
                                if $0 {
                                    selected.insert(agent)
                                } else {
                                    selected.remove(agent)
                                }
                            }
                        ))
                        .disabled(installations.isBusy)
                    } else {
                        Text(agent.name).font(.headline)
                    }
                    Spacer()
                    if let phase = entry.phase {
                        ProgressView().controlSize(.small)
                        Text(phase).font(.caption)
                        if let start = entry.startedAt {
                            Text(start, style: .timer).monospacedDigit().font(.caption)
                        }
                    } else {
                        availability(entry.availability, agent: agent)
                    }
                }
                if let installation = entry.managedInstallation {
                    HStack {
                        Text(installation.source.label).font(.caption).foregroundStyle(.secondary)
                        if let latest = entry.latestVersion {
                            Text(entry.updateAvailable ? "Latest v\(latest) available" : "Latest v\(latest)")
                                .font(.caption)
                                .foregroundStyle(entry.updateAvailable ? .orange : .secondary)
                        }
                        Spacer()
                        Button("Update") {
                            installations.maintain(agent, action: .update)
                        }
                        .accessibilityIdentifier("agentCLIUpdate-\(agent.id)")
                        Button("Repair Launch") {
                            installations.maintain(agent, action: .repair)
                        }
                        .help("Verify official signatures and clear download quarantine for this installation.")
                        .accessibilityIdentifier("agentCLIRepair-\(agent.id)")
                    }
                    .disabled(installations.isBusy)
                } else if case .available = entry.availability {
                    Text("Manage updates with this installation’s original installer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = entry.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }

        @ViewBuilder
        private func availability(_ status: AgentCLIAvailability?, agent: InstallableAgentCLI) -> some View {
            switch status {
            case let .available(path, version, _):
                Label(version, symbol: .checkmarkCircle).foregroundStyle(.green).help(path)
                Button("Open") { launch(agent) }.disabled(installations.isBusy || installations.entries[agent]?.error != nil)
            case .missing:
                Text("Not installed").foregroundStyle(.secondary)
            case let .unavailable(message):
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            case nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    struct AgentCLIStartupPrompt: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(\.appearsActive) private var isActive
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Color.clear.frame(width: 0, height: 0)
                .onChange(of: coordinator.agentCLIInstallations?.startupPromptPending, initial: true) { presentIfNeeded() }
                .onChange(of: isActive) { presentIfNeeded() }
                .onChange(of: coordinator.agentCLIInstallations?.isBusy) { presentIfNeeded() }
        }

        private func presentIfNeeded() {
            if coordinator.agentCLIInstallations?.consumeStartupPrompt(isActive: isActive) == true {
                openWindow(id: "agent-cli-setup")
            }
        }
    }
#endif
