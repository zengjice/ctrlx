#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Observation

    struct AgentCLIInstallation {
        var availability: AgentCLIAvailability?
        var phase: String?
        var startedAt: Date?
        var error: String?
        var log = ""
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
        private(set) var isInstalling = false
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
        private let command: (InstallableAgentCLI) -> String
        private let useInstalledCommand: (InstallableAgentCLI, String, String) async throws -> Void

        init(
            command: @escaping (InstallableAgentCLI) -> String,
            useInstalledCommand: @escaping (InstallableAgentCLI, String, String) async throws -> Void
        ) {
            self.command = command
            self.useInstalledCommand = useInstalledCommand
            @Dependency(PreferencesService.self) var preferences
            self.remindAtStartup = preferences.optionalBool(Self.reminderKey) ?? true
        }

        var missing: [InstallableAgentCLI] {
            InstallableAgentCLI.allCases.filter { entries[$0]?.availability == .missing }
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

        func install(_ selected: Set<InstallableAgentCLI>) {
            guard !isBusy else { return }
            let agents = InstallableAgentCLI.allCases.filter { selected.contains($0) && missing.contains($0) }
            guard !agents.isEmpty else { return }
            startupPromptPending = false
            isBusy = true
            isInstalling = true
            operation = Task {
                defer {
                    isBusy = false
                    isInstalling = false
                    operation = nil
                }
                for agent in agents {
                    guard !Task.isCancelled else { return }
                    entries[agent]?.error = nil
                    entries[agent]?.log = ""
                    entries[agent]?.startedAt = Date()
                    entries[agent]?.phase = "Checking installation"
                    // The user may have installed it elsewhere since the prompt appeared.
                    await check(agent)
                    guard entries[agent]?.availability == .missing else {
                        entries[agent]?.phase = nil
                        entries[agent]?.startedAt = nil
                        continue
                    }
                    let expectedCommand = command(agent)
                    do {
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
                    } catch {
                        // Cancellation is not rollback. Recheck using an uncancelled task before offering Retry.
                        await Task { await check(agent) }.value
                        entries[agent]?.error = Task.isCancelled ? "Installation cancelled. Any completed files were kept." : error.localizedDescription
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
            guard !Task.isCancelled else { return }
            entries[agent, default: .init()].error = nil
            guard command(agent) == expectedCommand else {
                entries[agent]?.availability = .unavailable("Command settings changed. Check again.")
                return
            }
            entries[agent, default: .init()].availability = result
            // Preserve PATH-resolved names so shell aliases and functions still apply at launch.
            if expectedCommand == agent.command, case let .available(path, _, true) = result {
                do {
                    try await useInstalledCommand(agent, path, expectedCommand)
                    commandRevision += 1
                } catch {
                    entries[agent]?.error = error.localizedDescription
                }
            }
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
