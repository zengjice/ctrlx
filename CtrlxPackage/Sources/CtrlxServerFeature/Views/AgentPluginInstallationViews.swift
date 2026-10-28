#if os(macOS)
    import CtrlxCommon
    import CtrlxPluginProtocol
    import SwiftUI

    struct AgentPluginUpdateBanner: View {
        @Environment(AppCoordinator.self) private var coordinator
        @Environment(AppSettings.self) private var settings
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            if let installations = coordinator.agentPluginInstallations, let location = installations.updates.first {
                HStack {
                    Label("A newer CtrlX plugin is available for \(displayName(location.pluginID)).", symbol: .infoCircle)
                    Spacer()
                    Button("Review in Settings…") {
                        coordinator.agentSettingsSelection = location.pluginID
                        settings.selectedSettingsTab = .agents
                        openSettings()
                        installations.dismiss(location)
                    }
                    Button("Dismiss") { installations.dismiss(location) }
                }
                .font(.callout)
                .padding(10)
                .background(.bar)
                .accessibilityIdentifier("agentPluginUpdateBanner")
            }
        }

        private func displayName(_ id: String) -> String {
            coordinator.agentPluginList().first { $0.id == id }?.name ?? id
        }
    }

    struct BundledAgentPluginRow: View {
        let installations: AgentPluginInstallations
        let location: AgentPluginLocation
        let folderPath: String
        let agentName: String
        let onRemove: (() -> Void)?

        private var state: AgentPluginInstallation {
            installations.installations[location] ?? .init()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(location.configRoot ?? folderPath).textSelection(.enabled)
                HStack {
                    statusLabel
                    Spacer()
                    if state.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check") { Task { await installations.refresh(location) } }
                    Button(installLabel) { Task { await installations.reinstall(location) } }
                        .disabled(state.bundledVersion == nil || state.status == .agentUnavailable)
                    if case .installed = state.status {
                        Button("Uninstall") { Task { await installations.uninstall(location) } }
                    }
                    if let onRemove {
                        Button("Remove Folder") {
                            installations.forget(location)
                            onRemove()
                        }
                    }
                }
                .controlSize(.small)
                .disabled(state.isBusy)
                if let version = state.bundledVersion {
                    Text("Bundled with this CtrlX: v\(version)\(state.updateAvailable ? " — update available" : "")")
                        .font(.caption).foregroundStyle(state.updateAvailable ? .orange : .secondary)
                }
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let change = state.lastChange {
                    Group {
                        if location.pluginID == "codex", change == .installed {
                            Text("New Codex sessions launched by CtrlX skip trust checks for all enabled hooks. If an existing session reports “hook approval required”, run /hooks and trust the updated hooks to continue without restarting.")
                        } else {
                            Text("Restart your \(agentName) sessions to load the changed CtrlX plugin. Running sessions have not been restarted.")
                        }
                    }
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("agentPluginInstallation-\(location.pluginID)-\(location.configRoot ?? "default")")
            .task(id: location) { await installations.refresh(location) }
        }

        private var installLabel: String {
            if case .notInstalled = state.status {
                return "Install"
            }
            return "Reinstall"
        }

        @ViewBuilder private var statusLabel: some View {
            switch state.status {
            case let .installed(version):
                Text(version.map { "Installed v\($0)" } ?? "Installed — version unknown")
            case .notInstalled: Text("Not installed")
            case .agentUnavailable: Text("Agent CLI not found").foregroundStyle(.orange)
            case let .checkFailed(message): Text("Check failed: \(message)").foregroundStyle(.red)
            case nil: Text("Checking installation…")
            }
        }
    }
#endif
