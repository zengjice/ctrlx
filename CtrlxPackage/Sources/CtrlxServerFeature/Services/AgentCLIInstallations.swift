#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Observation

    struct AgentCLIInstallation {
        var availability: AgentCLIAvailability?
        var managedInstallation: AgentCLIManagedInstallation?
        var latestVersion: String?
        var latestCheckedAt: Date?
        var updateCheckError: String?
        var phase: String?
        var startedAt: Date?
        var error: String?
        var log = ""

        var installedVersion: String? {
            guard case let .available(_, version, _) = availability else { return nil }
            return AgentCLIVersion.number(in: version)
        }

        var updateAvailable: Bool {
            guard
                let installedVersion,
                let latestVersion
            else { return false }
            return AgentCLIVersion.isNewer(latestVersion, than: installedVersion)
        }

        var updateErrorMessages: [String] {
            [error, updateCheckError].compactMap { $0 }.reduce(into: []) { messages, message in
                if !messages.contains(message) {
                    messages.append(message)
                }
            }
        }
    }

    struct AgentCLIUpdate: Identifiable, Equatable, Sendable {
        let agent: InstallableAgentCLI
        let installedVersion: String
        let latestVersion: String

        var id: String {
            "\(agent.id):\(latestVersion)"
        }
    }

    enum AgentCLICommandSettings {
        static func command(in data: Data, agent: InstallableAgentCLI) -> String {
            let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return settings?["command_path"] as? String ?? agent.command
        }

        static func adopting(_ path: String, expectedCommand: String, agent: InstallableAgentCLI, data: Data) throws -> Data {
            let object: Any = data.isEmpty ? [String: String]() : try JSONSerialization.jsonObject(with: data)
            guard var settings = object as? [String: Any] else { throw AgentCLIError(message: "Agent settings must be a JSON object.") }
            let current = settings["command_path"] as? String ?? agent.command
            guard current == expectedCommand else {
                throw AgentCLIError(message: "Command settings changed during installation. Check the path in Agents settings.")
            }
            settings["command_path"] = path
            return try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        }
    }

    /// App-owned work survives closing the installer window; all windows share one queue.
    @Observable @MainActor
    final class AgentCLIInstallations {
        private(set) var entries: [InstallableAgentCLI: AgentCLIInstallation] = [:]
        private(set) var isBusy = false
        private(set) var isPerformingOperation = false
        private(set) var startupPromptPending = false
        private(set) var commandRevision = 0
        var remindAtStartup: Bool {
            didSet { preferences.setBool(remindAtStartup, Self.reminderKey) }
        }

        static let reminderKey = "agentCLI.remindAtStartup"
        @ObservationIgnored @Dependency(AgentCLIClient.self) private var client
        @ObservationIgnored @Dependency(PreferencesService.self) private var preferences
        @ObservationIgnored private var operation: Task<Void, Never>?
        @ObservationIgnored private var startupChecked = false
        @ObservationIgnored private let reminders: AgentUpdateReminderStore
        private let command: (InstallableAgentCLI) -> String
        private let useInstalledCommand: (InstallableAgentCLI, String, String) async throws -> Void

        init(
            reminders: AgentUpdateReminderStore,
            command: @escaping (InstallableAgentCLI) -> String,
            useInstalledCommand: @escaping (InstallableAgentCLI, String, String) async throws -> Void
        ) {
            self.reminders = reminders
            self.command = command
            self.useInstalledCommand = useInstalledCommand
            @Dependency(PreferencesService.self) var preferences
            self.remindAtStartup = preferences.optionalBool(Self.reminderKey) ?? true
        }

        var missing: [InstallableAgentCLI] {
            InstallableAgentCLI.allCases.filter { entries[$0]?.availability == .missing }
        }

        var updates: [AgentCLIUpdate] {
            InstallableAgentCLI.allCases.compactMap { agent in
                guard
                    let entry = entries[agent],
                    let installedVersion = entry.installedVersion,
                    let latestVersion = entry.latestVersion,
                    AgentCLIVersion.isNewer(latestVersion, than: installedVersion),
                    reminders.shouldShow(.cli(agentID: agent.id, version: latestVersion))
                else { return nil }
                return AgentCLIUpdate(agent: agent, installedVersion: installedVersion, latestVersion: latestVersion)
            }
        }

        func start() {
            guard !startupChecked else { return }
            startupChecked = true
            refresh(atStartup: true)
        }

        func consumeStartupPrompt(isActive: Bool) -> Bool {
            guard isActive, startupPromptPending, !isBusy else { return false }
            startupPromptPending = false
            return remindAtStartup && !missing.isEmpty
        }

        func dismissStartupPrompt() {
            startupPromptPending = false
        }

        func refresh(atStartup: Bool = false) {
            guard !isBusy else { return }
            isBusy = true
            operation = Task {
                defer {
                    isBusy = false
                    operation = nil
                }
                for agent in InstallableAgentCLI.allCases {
                    guard !Task.isCancelled else { return }
                    await check(agent)
                }
                if atStartup {
                    startupPromptPending = remindAtStartup && !missing.isEmpty
                }
            }
        }

        func refresh(_ agent: InstallableAgentCLI) {
            guard !isBusy else { return }
            isBusy = true
            operation = Task {
                defer {
                    isBusy = false
                    operation = nil
                }
                await check(agent)
            }
        }

        func dismiss(_ update: AgentCLIUpdate) {
            guard entries[update.agent]?.latestVersion == update.latestVersion else { return }
            reminders.dismiss(.cli(agentID: update.agent.id, version: update.latestVersion))
        }

        func install(_ selected: Set<InstallableAgentCLI>) {
            guard !isBusy else { return }
            let agents = InstallableAgentCLI.allCases.filter { selected.contains($0) && missing.contains($0) }
            perform(agents)
        }

        func maintain(_ agent: InstallableAgentCLI, action: AgentCLIMaintenanceAction) {
            guard !isBusy, entries[agent]?.managedInstallation != nil else { return }
            perform([agent], action: action)
        }

        private func perform(_ agents: [InstallableAgentCLI], action: AgentCLIMaintenanceAction? = nil) {
            guard !agents.isEmpty else { return }
            let expectedCommands = Dictionary(uniqueKeysWithValues: agents.map { ($0, command($0)) })
            let targets = entries.compactMapValues(\.managedInstallation)
            startupPromptPending = false
            isBusy = true
            isPerformingOperation = true
            operation = Task {
                defer {
                    isBusy = false
                    isPerformingOperation = false
                    operation = nil
                }
                for agent in agents {
                    guard !Task.isCancelled else { return }
                    entries[agent]?.error = nil
                    entries[agent]?.log = ""
                    entries[agent]?.startedAt = Date()
                    entries[agent]?.phase = "Checking installation"
                    let expectedCommand = expectedCommands[agent] ?? command(agent)
                    do {
                        try Task.checkCancellation()
                        if let action {
                            let currentTarget = await client.managedInstallation(agent, expectedCommand)
                            guard let target = targets[agent], currentTarget == target, command(agent) == expectedCommand else {
                                throw AgentCLIError(message: "The agent installation or command changed. Check again before retrying.")
                            }
                            try await client.maintain(action, target) { [weak self] event in await self?.receive(event, for: agent) }
                            entries[agent]?.phase = "Verifying agent launch"
                            let result = await client.inspect(agent, expectedCommand)
                            guard command(agent) == expectedCommand, case .available = result else {
                                throw AgentCLIError(message: "The operation finished, but the configured agent could not be verified. Check the log and Agents command path.")
                            }
                            try await repairCommandPathIfNeeded(result, for: agent, expectedCommand: expectedCommand)
                            entries[agent]?.availability = result
                            entries[agent]?.managedInstallation = await client.managedInstallation(agent, expectedCommand)
                        } else {
                            // The user may have installed it elsewhere since the prompt appeared.
                            await check(agent)
                            if entries[agent]?.availability == .missing {
                                guard command(agent) == expectedCommand else {
                                    throw AgentCLIError(message: "Command settings changed. Check again.")
                                }
                                try Task.checkCancellation()
                                try await client.install(agent) { [weak self] event in await self?.receive(event, for: agent) }
                                entries[agent]?.phase = "Verifying installation"
                                let result = await client.inspect(agent, agent.nativePath())
                                guard case let .available(path, _, _) = result else {
                                    throw AgentCLIError(message: "Installer finished, but the native CLI could not be verified. Check the log and Agents command path.")
                                }
                                try await useInstalledCommand(agent, path, expectedCommand)
                                commandRevision += 1
                                entries[agent]?.availability = result
                                entries[agent]?.managedInstallation = await client.managedInstallation(agent, path)
                            }
                        }
                    } catch {
                        // Cancellation is not rollback. Recheck using an uncancelled task before offering Retry.
                        await Task { await check(agent) }.value
                        entries[agent]?.error = Task.isCancelled ? "Operation cancelled. Any completed files were kept." : error.localizedDescription
                    }
                    entries[agent]?.phase = nil
                    entries[agent]?.startedAt = nil
                }
            }
        }

        func cancel() {
            operation?.cancel()
        }

        func waitForOperation() async {
            await operation?.value
        }

        func stop() async {
            operation?.cancel()
            await operation?.value
        }

        private func check(_ agent: InstallableAgentCLI) async {
            let expectedCommand = command(agent)
            let result = await client.inspect(agent, expectedCommand)
            let managedInstallation = await client.managedInstallation(agent, expectedCommand)
            guard !Task.isCancelled else { return }
            entries[agent, default: .init()].error = nil
            guard command(agent) == expectedCommand else {
                entries[agent]?.availability = .unavailable("Command settings changed. Check again.")
                entries[agent]?.managedInstallation = nil
                return
            }
            entries[agent, default: .init()].availability = result
            entries[agent]?.managedInstallation = managedInstallation
            if case .available = result {
                await checkLatestVersion(agent)
            } else {
                entries[agent]?.latestVersion = nil
                entries[agent]?.latestCheckedAt = nil
                entries[agent]?.updateCheckError = nil
            }
            do {
                try await repairCommandPathIfNeeded(result, for: agent, expectedCommand: expectedCommand)
            } catch {
                entries[agent]?.error = error.localizedDescription
            }
        }

        private func checkLatestVersion(_ agent: InstallableAgentCLI) async {
            do {
                let latest = try await client.latestVersion(agent)
                guard !Task.isCancelled else { return }
                entries[agent]?.latestVersion = latest
                entries[agent]?.latestCheckedAt = Date()
                entries[agent]?.updateCheckError = nil
            } catch {
                guard !Task.isCancelled else { return }
                entries[agent]?.updateCheckError = error.localizedDescription
            }
        }

        private func repairCommandPathIfNeeded(_ result: AgentCLIAvailability, for agent: InstallableAgentCLI, expectedCommand: String) async throws {
            // Preserve PATH-resolved names so shell aliases and functions still apply at launch.
            guard expectedCommand == agent.command, case let .available(path, _, true) = result else { return }
            try Task.checkCancellation()
            try await useInstalledCommand(agent, path, expectedCommand)
            commandRevision += 1
        }

        private func receive(_ event: AgentCLIInstallEvent, for agent: InstallableAgentCLI) {
            switch event {
            case let .phase(phase): entries[agent]?.phase = phase
            case let .output(text):
                let combined = (entries[agent]?.log ?? "") + text
                entries[agent]?.log = String(combined.suffix(128 * 1_024))
            }
        }
    }
#endif
