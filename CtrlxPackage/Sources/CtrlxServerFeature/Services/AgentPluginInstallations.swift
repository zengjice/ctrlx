#if os(macOS)
    import CtrlxCommon
    import CtrlxPluginProtocol
    import Foundation
    import Observation

    struct AgentPluginLocation: Hashable, Sendable {
        let pluginID: String
        let configRoot: String?

        init(
            pluginID: String,
            configRoot: String?,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            home: URL = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.pluginID = pluginID
            let variable = pluginID == "codex" ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
            let override = environment[variable].flatMap { $0.isEmpty ? nil : $0 }
            let path = configRoot ?? override ?? home.appendingPathComponent(pluginID == "codex" ? ".codex" : ".claude").path
            // Capture the actual default once, so the displayed folder matches
            // the CLI target and a duplicate default row cannot bypass the lock.
            self.configRoot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        }
    }

    struct AgentPluginInstallation: Sendable {
        enum Change: Sendable {
            case installed
            case uninstalled
        }

        var status: PluginInstallStatus?
        var bundledVersion: String?
        var isBusy = false
        var error: String?
        var lastChange: Change?

        var updateAvailable: Bool {
            guard case let .installed(version) = status, let bundledVersion else { return false }
            return AgentPluginResourceClient.updateAvailable(installed: version, bundled: bundledVersion)
        }
    }

    /// Local Agent installation state, shared by startup checks and settings.
    /// Per-location serialization keeps a slow check from overwriting a reinstall.
    @Observable @MainActor
    final class AgentPluginInstallations {
        private(set) var installations: [AgentPluginLocation: AgentPluginInstallation] = [:]
        @ObservationIgnored private var startupChecked = false
        @ObservationIgnored private let reminders: AgentUpdateReminderStore
        @ObservationIgnored private let core: (String) async -> (any AgentPluginMaintenance)?

        init(
            reminders: AgentUpdateReminderStore,
            core: @escaping (String) async -> (any AgentPluginMaintenance)?
        ) {
            self.reminders = reminders
            self.core = core
        }

        var updates: [AgentPluginLocation] {
            installations.keys.filter { location in
                guard
                    installations[location]?.updateAvailable == true,
                    let version = installations[location]?.bundledVersion
                else { return false }
                return reminders.shouldShow(
                    .plugin(pluginID: location.pluginID, configRoot: location.configRoot, version: version)
                )
            }
            .sorted { ($0.pluginID, $0.configRoot ?? "") < ($1.pluginID, $1.configRoot ?? "") }
        }

        func dismiss(_ location: AgentPluginLocation) {
            guard
                installations[location]?.updateAvailable == true,
                let version = installations[location]?.bundledVersion
            else { return }
            reminders.dismiss(
                .plugin(pluginID: location.pluginID, configRoot: location.configRoot, version: version)
            )
        }

        func forget(_ location: AgentPluginLocation) {
            guard installations[location]?.isBusy != true else { return }
            installations.removeValue(forKey: location)
        }

        func checkAtStartup(_ locations: [AgentPluginLocation]) async {
            guard !startupChecked else { return }
            startupChecked = true
            var seen: Set<AgentPluginLocation> = []
            for location in locations where seen.insert(location).inserted {
                guard !Task.isCancelled else { return }
                await refresh(location)
            }
        }

        func refresh(_ location: AgentPluginLocation) async {
            guard installations[location]?.isBusy != true else { return }
            installations[location, default: .init()].isBusy = true
            defer { installations[location]?.isBusy = false }
            guard let core = await core(location.pluginID) else {
                installations[location]?.status = .agentUnavailable
                return
            }
            installations[location]?.status = await core.installStatus(configRoot: location.configRoot)
            do {
                installations[location]?.bundledVersion = try await core.bundledPluginVersion()
                installations[location]?.error = nil
            } catch {
                installations[location]?.bundledVersion = nil
                installations[location]?.error = error.localizedDescription
            }
        }

        func reinstall(_ location: AgentPluginLocation) async {
            await perform(location, uninstall: false)
        }

        func uninstall(_ location: AgentPluginLocation) async {
            await perform(location, uninstall: true)
        }

        private func perform(_ location: AgentPluginLocation, uninstall: Bool) async {
            guard installations[location]?.isBusy != true else { return }
            installations[location, default: .init()].isBusy = true
            installations[location]?.error = nil
            installations[location]?.lastChange = nil
            defer { installations[location]?.isBusy = false }
            guard let core = await core(location.pluginID) else {
                installations[location]?.status = .agentUnavailable
                return
            }
            do {
                if uninstall {
                    try await core.uninstall(configRoot: location.configRoot)
                } else {
                    _ = try await core.reinstall(configRoot: location.configRoot)
                }
                installations[location]?.lastChange = uninstall ? .uninstalled : .installed
            } catch {
                installations[location]?.error = error.localizedDescription
            }
            // Query even on failure: removal may have succeeded before an add failed.
            installations[location]?.status = await core.installStatus(configRoot: location.configRoot)
        }
    }
#endif
