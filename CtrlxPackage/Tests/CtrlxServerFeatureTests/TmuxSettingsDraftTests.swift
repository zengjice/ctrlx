import CtrlxCommon
import CtrlxEncryption
import Dependencies
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct TmuxSettingsDraftTests {
    @Test("Saving the next launch leaves all running configuration unchanged")
    func stageWithoutReconfiguring() {
        let preferences = PreferencesService.inMemory()
        withDependencies {
            $0[PreferencesService.self] = preferences
        } operation: {
            let settings = AppSettings()
            let running = settings.savedTmuxConfiguration
            let next = TmuxSettingsDraft(tmuxPath: "/fixture/tmux", socketPath: "/tmp/fixture.sock")
            settings.saveTmuxConfigurationForNextLaunch(next)
            #expect(settings.tmuxPath == running.tmuxPath)
            #expect(settings.tmuxSocket == running.socketPath)
            #expect(settings.pendingTmuxConfiguration == next)
            #expect(AppSettings().savedTmuxConfiguration == next)

            // Saving the running configuration cancels a pending restart change.
            settings.saveTmuxConfigurationForNextLaunch(running)
            #expect(settings.pendingTmuxConfiguration == nil)
            #expect(AppSettings().savedTmuxConfiguration == running)
        }
    }

    @Test("Command validation resolves PATH and normalizes the draft before saving")
    func resolveAndNormalize() async throws {
        try await withDependencies {
            $0[AgentResumeExecutableClient.self].resolve = { recorded, configured in
                #expect(recorded == nil)
                #expect(configured == "tmux")
                return "/fixture/bin/tmux"
            }
        } operation: {
            let normalized = try await TmuxSettingsDraft(tmuxPath: " tmux ", socketPath: " /tmp/work.sock ").validated()
            #expect(normalized == .init(tmuxPath: "/fixture/bin/tmux", socketPath: "/tmp/work.sock"))
        }
    }

    @Test("Invalid socket drafts are rejected before resolving an executable", arguments: ["relative.sock", "/tmp/a\nsocket"])
    func invalidSocket(socket: String) async {
        await withDependencies {
            $0[AgentResumeExecutableClient.self].resolve = { _, _ in
                Issue.record("Invalid drafts must not reach executable resolution")
                return "/fixture/tmux"
            }
        } operation: {
            await #expect(throws: SettingsConfigurationError.self) {
                try await TmuxSettingsDraft(tmuxPath: "tmux", socketPath: socket).validated()
            }
        }
    }

    @Test("A named Agent command keeps following PATH instead of pinning a CLI version")
    func agentCommandFollowsPath() async throws {
        try await withDependencies {
            $0[AgentResumeExecutableClient.self].resolve = { _, _ in "/fixture/version-1/bin/codex" }
        } operation: {
            let command = try await SettingsCommandValidation.resolve(" codex ", preserveCommandName: true)
            #expect(command == "codex")
        }
    }

    @Test("Empty or multiline command drafts are rejected", arguments: ["", "  ", "codex\nother"])
    func invalidCommand(command: String) async {
        await #expect(throws: SettingsConfigurationError.self) {
            try await SettingsCommandValidation.resolve(command)
        }
    }

    @Test("An unresolved executable leaves preferences untouched")
    func invalidExecutableDoesNotSave() async {
        await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[AgentResumeExecutableClient.self].resolve = { _, path in
                throw ProcessRunnerError.executableNotFound(path: path)
            }
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            let coordinator = AppCoordinator()
            let original = coordinator.settings.savedTmuxConfiguration
            await #expect(throws: ProcessRunnerError.self) {
                try await coordinator.saveTmuxConfigurationForNextLaunch(.init(tmuxPath: "/missing/tmux", socketPath: ""))
            }
            #expect(coordinator.settings.savedTmuxConfiguration == original)
            #expect(coordinator.settings.pendingTmuxConfiguration == nil)
            #expect(AppSettings().savedTmuxConfiguration == original)
        }
    }
}
