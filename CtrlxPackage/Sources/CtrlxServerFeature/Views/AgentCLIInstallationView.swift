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
