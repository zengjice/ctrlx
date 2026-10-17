#if os(macOS)
    import CtrlxCommon
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Native Agent CLI setup") @MainActor
    struct AgentCLIInstallationsTests {
        private actor Fixture {
            var statuses: [InstallableAgentCLI: AgentCLIAvailability] = [:]
            var installed: [InstallableAgentCLI] = []
            var adoptedCommands: [String] = []
            var failCodex = false
            var waitDuringInstall = false
            let started = AsyncStream<Void>.makeStream()

            func inspect(_ agent: InstallableAgentCLI) -> AgentCLIAvailability {
                statuses[agent] ?? .missing
            }

            func set(_ status: AgentCLIAvailability, for agent: InstallableAgentCLI) {
                statuses[agent] = status
            }

            func adopt(_ path: String) {
                adoptedCommands.append(path)
            }

            func configure(failCodex: Bool = false, wait: Bool = false) {
                self.failCodex = failCodex
                waitDuringInstall = wait
            }

            func install(_ agent: InstallableAgentCLI, event: @Sendable (AgentCLIInstallEvent) async -> Void) async throws {
                installed.append(agent)
                await event(.phase("Running official installer"))
                await event(.output("Real installer output\n"))
                started.continuation.yield(())
                if waitDuringInstall {
                    try await Task.sleep(for: .seconds(60))
                }
                if agent == .codex, failCodex {
                    throw AgentCLIError(message: "fixture download failed")
                }
                statuses[agent] = .available(path: agent.nativePath(), version: "1.2.3")
            }
        }

        private func make(_ fixture: Fixture, preferences: PreferencesService = .inMemory()) -> AgentCLIInstallations {
            withDependencies {
                $0[PreferencesService.self] = preferences
                $0[AgentCLIClient.self] = .init(inspect: { agent, _ in await fixture.inspect(agent) }, install: { agent, event in try await fixture.install(agent, event: event) })
            } operation: {
                AgentCLIInstallations(command: { $0.command }, useInstalledCommand: { _, path, _ in await fixture.adopt(path) })
            }
        }

        @Test("Startup only detects; prompt waits for activation, is consumed once, and never installs without a click")
        func startupConsent() async {
            let fixture = Fixture()
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            #expect(state.missing.count == 2)
            #expect(!state.consumeStartupPrompt(isActive: false))
            #expect(state.consumeStartupPrompt(isActive: true))
            #expect(!state.consumeStartupPrompt(isActive: true))
            state.start()
            await state.waitForOperation()
            #expect(!state.startupPromptPending)
            #expect(await fixture.installed.isEmpty)
        }

        @Test("Opting out persists, without disabling manual installation")
        func reminder() async {
            let preferences = PreferencesService.inMemory()
            let fixture = Fixture()
            let first = make(fixture, preferences: preferences)
            first.remindAtStartup = false
            let state = make(fixture, preferences: preferences)
            state.start()
            await state.waitForOperation()
            #expect(!state.consumeStartupPrompt(isActive: true))
            state.install([.codex])
            await state.waitForOperation()
            #expect(await fixture.installed == [.codex])
        }

        @Test("Existing or broken CLIs never enter the installer")
        func installedAndBroken() async {
            let fixture = Fixture()
            await fixture.set(.available(path: "/existing/codex", version: "old but working"), for: .codex)
            await fixture.set(.unavailable("custom command failed"), for: .claudeCode)
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            state.install(Set(InstallableAgentCLI.allCases))
            await state.waitForOperation()
            #expect(state.missing.isEmpty)
            #expect(!state.startupPromptPending)
            #expect(await fixture.installed.isEmpty)
        }

        @Test("Startup and manual checks preserve bare commands already resolved through PATH", arguments: InstallableAgentCLI.allCases)
        func preservesPathCommand(agent: InstallableAgentCLI) async {
            let fixture = Fixture()
            await fixture.set(.available(path: agent.nativePath(), version: "1.2.3"), for: agent)
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            state.refresh()
            await state.waitForOperation()
            #expect(await fixture.adoptedCommands.isEmpty)
            #expect(state.commandRevision == 0)
            #expect(await fixture.installed.isEmpty)
        }

        @Test("Known fallback launchers outside PATH are adopted without reinstalling", arguments: InstallableAgentCLI.allCases)
        func repairsMissingPath(agent: InstallableAgentCLI) async {
            let fixture = Fixture()
            await fixture.set(.available(path: agent.nativePath(), version: "1.2.3", requiresPathRepair: true), for: agent)
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            #expect(await fixture.adoptedCommands == [agent.nativePath()])
            #expect(state.commandRevision == 1)
            #expect(state.entries[agent]?.error == nil)
            #expect(await fixture.installed.isEmpty)
        }

        @Test("An error in the first installer does not block the second or erase logs")
        func failureAndRetry() async {
            let fixture = Fixture()
            await fixture.configure(failCodex: true)
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            state.install(Set(InstallableAgentCLI.allCases))
            await state.waitForOperation()
            #expect(await fixture.installed == [.codex, .claudeCode])
            #expect(state.entries[.codex]?.error == "fixture download failed")
            #expect(state.entries[.codex]?.log.contains("Real installer output") == true)
            #expect(state.entries[.claudeCode]?.availability == .available(path: InstallableAgentCLI.claudeCode.nativePath(), version: "1.2.3"))
            await fixture.configure()
            state.install([.codex])
            await state.waitForOperation()
            #expect(state.entries[.codex]?.error == nil)
            #expect(state.missing.isEmpty)
        }

        @Test("Concurrent clicks share a job, logs arrive before completion, cancel stops the queue")
        func cancellation() async {
            let fixture = Fixture()
            await fixture.configure(wait: true)
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            state.install(Set(InstallableAgentCLI.allCases))
            var events = fixture.started.stream.makeAsyncIterator()
            _ = await events.next()
            #expect(state.isInstalling)
            #expect(state.entries[.codex]?.log.isEmpty == false)
            state.install([.claudeCode])
            state.refresh()
            state.cancel()
            await state.waitForOperation()
            #expect(!state.isBusy)
            #expect(await fixture.installed == [.codex])
            #expect(state.entries[.codex]?.error?.contains("cancelled") == true)
        }

        @Test("Native paths preserve other settings and do not overwrite a command edited during installation")
        func commandSettings() throws {
            let original = Data(#"{"command_path":"codex","auto_run":false,"future_field":{"value":42}}"#.utf8)
            let data = try AgentCLICommandSettings.adopting("/native/bin/codex", expectedCommand: "codex", agent: .codex, data: original)
            let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(decoded["command_path"] as? String == "/native/bin/codex")
            #expect(decoded["auto_run"] as? Bool == false)
            #expect((decoded["future_field"] as? [String: Int])?["value"] == 42)
            #expect(throws: AgentCLIError.self) {
                try AgentCLICommandSettings.adopting("/new/codex", expectedCommand: "codex", agent: .codex, data: data)
            }
            #expect(throws: AgentCLIError.self) {
                try AgentCLICommandSettings.adopting("/new/codex", expectedCommand: "codex", agent: .codex, data: Data("[]".utf8))
            }
        }

        @Test("Recheck immediately before installing preserves an installation made outside CtrlX")
        func installedElsewhere() async {
            let fixture = Fixture()
            let state = make(fixture)
            state.start()
            await state.waitForOperation()
            await fixture.set(.available(path: "/brew/codex", version: "1"), for: .codex)
            state.install([.codex])
            await state.waitForOperation()
            #expect(await fixture.installed.isEmpty)
        }
    }
#endif
