#if os(macOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxEncryption
    import CtrlxPluginProtocol
    import Dependencies
    import Foundation
    import Testing
    @testable import CodexPluginCore
    @testable import CtrlxServerFeature

    @Suite("AgentsSettingsSupport")
    @MainActor
    struct AgentsSettingsSupportTests {
        // MARK: - Helpers

        /// Builds a fresh temp-dir `CtrlxPaths` and injects it into a new
        /// `AppCoordinator` so settings read/write goes to an isolated directory.
        private func makeCoordinator() -> (coordinator: AppCoordinator, root: URL) {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ctrlx-agents-settings-\(UUID().uuidString)")
                .appendingPathComponent("state")
            let paths = CtrlxPaths(stateRootOverride: root)
            paths.ensureBaseDirectories()

            let coordinator = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: {
                AppCoordinator()
            }
            coordinator.ctrlxPaths = paths
            coordinator.pluginDispatcher = PluginEventDispatcher()
            return (coordinator, root)
        }

        private func enableCodex(_ coordinator: AppCoordinator, root: URL, settings: Data) async throws -> CodexPluginCore {
            let registry = PluginRegistry()
            coordinator.pluginRegistry = registry
            await registry.enable("codex", host: MockPluginHost(), env: PluginEnv(
                pluginRoot: root.appendingPathComponent("plugin"),
                stateDir: root.appendingPathComponent("codex"),
                appVersion: "test", settings: settings, marketplaceSource: root
            ))
            return try #require(registry.core("codex") as? CodexPluginCore)
        }

        private var provider: CodexProviderProfile {
            .init(id: "team", name: "Base", baseURL: "https://api.example.com/v1", model: "base", environmentKey: "FIXTURE_API_KEY")
        }

        @Test("Re-enable reads the final settings after a pending save succeeds or rolls back", arguments: [false, true], [false, true])
        func lifecycleDuringSave(saveSucceeds: Bool, viaCLI: Bool) async throws {
            try await withMainSerialExecutor {
                let (coordinator, root) = makeCoordinator()
                defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
                let original = try JSONEncoder().encode(CodexSettings(providers: [provider]))
                #expect(await coordinator.setPluginSettings(id: "codex", original) == nil)
                let oldCore = try await enableCodex(coordinator, root: root, settings: original)
                let registry = try #require(coordinator.pluginRegistry)
                let settingsURL = try #require(coordinator.ctrlxPaths).pluginSettingsPath("codex")
                var edited = provider
                edited.name = "Edited"
                edited.model = "edited"
                let candidate = try JSONEncoder().encode(CodexSettings(providers: [edited]))
                let started = AsyncStream<Void>.makeStream()
                let release = AsyncStream<Void>.makeStream()
                let calls = LockIsolated(0)
                let restarted = LockIsolated(false)
                await withDependencies {
                    $0[CodexProviderConfigurationClient.self].synchronize = { _, _, _ in
                        let call = calls.withValue { $0 += 1
                            return $0
                        }
                        if call == 1 {
                            started.continuation.yield(())
                            var iterator = release.stream.makeAsyncIterator()
                            _ = await iterator.next()
                            if !saveSucceeds {
                                throw AgentProviderError("Fixture: rejected configuration")
                            }
                        }
                    }
                } operation: {
                    let save = Task { await coordinator.setPluginSettings(id: "codex", candidate) }
                    var iterator = started.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    let restart = Task {
                        if viaCLI {
                            #expect(await coordinator.disablePluginViaCLI("codex") == false)
                            #expect(await coordinator.enablePluginViaCLI("codex") == true)
                        } else {
                            await registry.disable("codex")
                            await registry.enable("codex", host: MockPluginHost(), makeEnv: {
                                PluginEnv(
                                    pluginRoot: root,
                                    stateDir: root.appendingPathComponent("codex"),
                                    appVersion: "test",
                                    settings: (try? Data(contentsOf: settingsURL)) ?? Data(),
                                    marketplaceSource: root
                                )
                            })
                        }
                        restarted.setValue(true)
                    }
                    await Task.megaYield()
                    #expect(!restarted.value)
                    #expect(registry.core("codex") === oldCore)
                    #expect(coordinator.pluginSettingsData(id: "codex") == original)
                    release.continuation.yield(())
                    let error = await save.value
                    #expect(saveSucceeds ? error == nil : error?.contains("rejected") == true)
                    await restart.value
                }
                let core = try #require(registry.core("codex") as? CodexPluginCore)
                let expected = saveSucceeds ? candidate : original
                #expect(core !== oldCore)
                #expect(coordinator.pluginSettingsData(id: "codex") == expected)
                #expect((try? Data(contentsOf: settingsURL)) == expected)
                let options = CodexSettings.decode(from: expected).providerOptions
                #expect(await core.providerOptions() == options)
                #expect(coordinator.localAgentLaunchAgents().first { $0.id == "codex" }?.providers == options)
                await registry.disable("codex")
            }
        }

        @Test("CLI command adoption merges the committed Provider and rechecks a changed command", arguments: [false, true])
        func adoptCommandDuringSave(userChangedCommand: Bool) async throws {
            try await withMainSerialExecutor {
                let (coordinator, root) = makeCoordinator()
                defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
                let original = try JSONEncoder().encode(CodexSettings(autoRun: false, providers: [provider]))
                #expect(await coordinator.setPluginSettings(id: "codex", original) == nil)
                let core = try await enableCodex(coordinator, root: root, settings: original)
                let revision = coordinator.pluginSettingsRevision
                var edited = provider
                edited.name = "Edited"
                edited.models = ["new-model"]
                let settings = CodexSettings(commandPath: userChangedCommand ? "/user/codex" : "codex", autoRun: false, providers: [edited])
                var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
                object["future_field"] = ["value": 42]
                let candidate = try JSONSerialization.data(withJSONObject: object)
                let started = AsyncStream<Void>.makeStream()
                let release = AsyncStream<Void>.makeStream()
                let calls = LockIsolated(0)
                let adopted = LockIsolated(false)
                await withDependencies {
                    $0[CodexProviderConfigurationClient.self].synchronize = { _, _, _ in
                        let call = calls.withValue { $0 += 1
                            return $0
                        }
                        if call == 1 {
                            started.continuation.yield(())
                            var iterator = release.stream.makeAsyncIterator()
                            _ = await iterator.next()
                        }
                    }
                } operation: {
                    let save = Task { await coordinator.setPluginSettings(id: "codex", candidate) }
                    var iterator = started.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    let adoption = Task { () -> String? in
                        defer { adopted.setValue(true) }
                        do {
                            try await coordinator.adoptAgentCLICommand(.codex, path: "/installed/codex", expectedCommand: "codex")
                            return nil
                        } catch { return error.localizedDescription }
                    }
                    await Task.megaYield()
                    #expect(!adopted.value)
                    release.continuation.yield(())
                    #expect(await save.value == nil)
                    let error = await adoption.value
                    #expect(userChangedCommand ? error?.contains("Command settings changed") == true : error == nil)
                }
                let saved = coordinator.pluginSettingsData(id: "codex")
                let decoded = CodexSettings.decode(from: saved)
                #expect(decoded.providers == [edited])
                #expect(decoded.commandPath == (userChangedCommand ? "/user/codex" : "/installed/codex"))
                #expect(!decoded.autoRun)
                let savedObject = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
                #expect((savedObject["future_field"] as? [String: Int])?["value"] == 42)
                #expect(await core.providerOptions() == decoded.providerOptions)
                #expect(coordinator.pluginSettingsRevision == revision + (userChangedCommand ? 1 : 2))
                let settingsURL = try #require(coordinator.ctrlxPaths).pluginSettingsPath("codex")
                #expect((try? Data(contentsOf: settingsURL)) == saved)
                await coordinator.pluginRegistry?.disable("codex")
            }
        }

        // MARK: - Settings round-trip

        @Test("pluginSettingsData returns empty data when no file exists yet")
        func settingsDataEmptyBeforeWrite() {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            let data = coordinator.pluginSettingsData(id: "claude-code")
            #expect(data.isEmpty)
        }

        @Test("setPluginSettings persists bytes that pluginSettingsData reads back verbatim")
        func settingsRoundTrip() async {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            let payload = Data(#"{"commandPath":"/usr/local/bin/claude","autoRun":true}"#.utf8)
            let error = await coordinator.setPluginSettings(id: "claude-code", payload)
            #expect(error == nil)

            let readBack = coordinator.pluginSettingsData(id: "claude-code")
            #expect(readBack == payload)
        }

        @Test("setPluginSettings surfaces an error when plugin state is not initialised")
        func settingsErrorWithoutPaths() async {
            // A coordinator with no injected ctrlxPaths must surface a failure
            // instead of silently swallowing the write (which would leave the live
            // core diverged from disk).
            let coordinator = withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            } operation: {
                AppCoordinator()
            }

            let error = await coordinator.setPluginSettings(id: "claude-code", Data("{}".utf8))
            #expect(error != nil)
        }

        @Test("setPluginSettings overwrites an existing file")
        func settingsOverwrite() async {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            let first = Data(#"{"commandPath":"/v1","autoRun":false}"#.utf8)
            let second = Data(#"{"commandPath":"/v2","autoRun":true}"#.utf8)

            await coordinator.setPluginSettings(id: "codex", first)
            await coordinator.setPluginSettings(id: "codex", second)

            let readBack = coordinator.pluginSettingsData(id: "codex")
            #expect(readBack == second)
        }

        @Test("The save entry surfaces native synchronization errors and restores committed settings", arguments: [false, true])
        func rejectedNativeSave(existingFile: Bool) async throws {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let original = existingFile ? try JSONEncoder().encode(CodexSettings(autoRun: false)) : Data()
            if existingFile {
                #expect(await coordinator.setPluginSettings(id: "codex", original) == nil)
            }
            let core = try await enableCodex(coordinator, root: root, settings: original)
            let revision = coordinator.pluginSettingsRevision
            let updated = try JSONEncoder().encode(CodexSettings(providers: [provider], defaultProviderID: provider.id))
            await withDependencies {
                $0[CodexProviderConfigurationClient.self].synchronize = { _, _, _ in
                    throw AgentProviderError("Fixture: native configuration is read-only")
                }
            } operation: {
                let error = await coordinator.setPluginSettings(id: "codex", updated)
                #expect(error?.contains("read-only") == true)
            }
            let settingsURL = try #require(coordinator.ctrlxPaths).pluginSettingsPath("codex")
            #expect((try? Data(contentsOf: settingsURL)) == (existingFile ? original : nil))
            #expect(coordinator.pluginSettingsData(id: "codex") == original)
            #expect(await core.providerOptions() == [CodexSettings.builtInProvider])
            #expect(coordinator.localAgentLaunchAgents().first { $0.id == "codex" }?.providers == [CodexSettings.builtInProvider])
            #expect(coordinator.pluginSettingsRevision == revision)

            // A rejected request must not poison the next successful save.
            #expect(await coordinator.setPluginSettings(id: "codex", updated) == nil)
            #expect(coordinator.pluginSettingsData(id: "codex") == updated)
            #expect(await core.providerOptions().contains { $0.id == provider.id })
            #expect(coordinator.localAgentLaunchAgents().first { $0.id == "codex" }?.providers.contains { $0.id == provider.id } == true)
            #expect(coordinator.pluginSettingsRevision == revision + 1)
            await coordinator.pluginRegistry?.disable("codex")
        }

        @Test("A settings-file failure leaves the live core and presentation unchanged")
        func settingsFileFailure() async throws {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            let settingsURL = try #require(coordinator.ctrlxPaths).pluginSettingsPath("codex")
            let directory = settingsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = try JSONEncoder().encode(CodexSettings(autoRun: false))
            try original.write(to: settingsURL)
            let core = try await enableCodex(coordinator, root: root, settings: original)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            let updated = try JSONEncoder().encode(CodexSettings(providers: [provider]))
            await withDependencies {
                $0[CodexProviderConfigurationClient.self].synchronize = { _, _, _ in
                    Issue.record("The core must not apply settings that could not be written")
                }
            } operation: {
                #expect(await coordinator.setPluginSettings(id: "codex", updated) != nil)
            }
            #expect(await core.providerOptions() == [CodexSettings.builtInProvider])
            #expect((try? Data(contentsOf: settingsURL)) == original)
            #expect(coordinator.localAgentLaunchAgents().first { $0.id == "codex" }?.providers == [CodexSettings.builtInProvider])
            #expect(coordinator.pluginSettingsRevision == 0)
            await coordinator.pluginRegistry?.disable("codex")
        }

        @Test("A suspended save cannot overwrite a later deletion or edit", arguments: [false, true])
        func orderedSaves(deleteLastProvider: Bool) async throws {
            try await withMainSerialExecutor {
                let (coordinator, root) = makeCoordinator()
                defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
                let original = try JSONEncoder().encode(CodexSettings(providers: [provider]))
                #expect(await coordinator.setPluginSettings(id: "codex", original) == nil)
                let core = try await enableCodex(coordinator, root: root, settings: original)
                let revision = coordinator.pluginSettingsRevision
                var old = provider
                old.model = "old"
                old.name = "Old"
                var latest = provider
                latest.model = "latest"
                latest.name = "Latest"
                let firstData = try JSONEncoder().encode(CodexSettings(providers: [old]))
                let latestData = try JSONEncoder().encode(CodexSettings(providers: deleteLastProvider ? [] : [latest]))
                let started = AsyncStream<Void>.makeStream()
                let release = AsyncStream<Void>.makeStream()
                let secondFinished = LockIsolated(false)
                let models = LockIsolated<[String]>([])
                await withDependencies {
                    $0[CodexProviderConfigurationClient.self].synchronize = { _, _, profiles in
                        let model = profiles.first?.model ?? ""
                        models.withValue { $0.append(model) }
                        if model == "old" {
                            started.continuation.yield(())
                            var iterator = release.stream.makeAsyncIterator()
                            _ = await iterator.next()
                        }
                    }
                } operation: {
                    let first = Task { await coordinator.setPluginSettings(id: "codex", firstData) }
                    var iterator = started.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    #expect(coordinator.pluginSettingsData(id: "codex") == original)
                    #expect(coordinator.localAgentLaunchAgents().first { $0.id == "codex" }?.providers.last?.name == "Base")
                    let second = Task {
                        let result = await coordinator.setPluginSettings(id: "codex", latestData)
                        secondFinished.setValue(true)
                        return result
                    }
                    await Task.megaYield()
                    #expect(!secondFinished.value)
                    #expect(models.value == ["old"])
                    #expect(await core.providerOptions().last?.name == "Base")
                    // A blocked Codex save must not block another plugin.
                    #expect(await coordinator.setPluginSettings(id: "claude-code", Data("{}".utf8)) == nil)
                    release.continuation.yield(())
                    #expect(await first.value == nil)
                    #expect(await second.value == nil)
                }
                #expect(models.value == (deleteLastProvider ? ["old"] : ["old", "latest"]))
                #expect(coordinator.pluginSettingsData(id: "codex") == latestData)
                let settingsURL = try #require(coordinator.ctrlxPaths).pluginSettingsPath("codex")
                #expect((try? Data(contentsOf: settingsURL)) == latestData)
                let expected = [CodexSettings.builtInProvider] + (deleteLastProvider ? [] : [.init(id: latest.id, name: latest.name)])
                #expect(await core.providerOptions() == expected)
                #expect(coordinator.localAgentLaunchAgents().first { $0.id == "codex" }?.providers == expected)
                #expect(coordinator.pluginSettingsRevision == revision + 3)
                await coordinator.pluginRegistry?.disable("codex")
            }
        }

        // MARK: - agentPluginList

        @Test("agentPluginList returns empty when registry is not initialised")
        func agentPluginListNoRegistry() {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            // pluginRegistry is nil until setupAllServices() runs; list must be empty.
            let list = coordinator.agentPluginList()
            #expect(list.isEmpty)
        }

        @Test("agentPluginList excludes echo and maps displayName from the manifest")
        func agentPluginListExcludesEcho() {
            let (coordinator, root) = makeCoordinator()
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

            // Inject a live registry (no cores enabled — list only needs manifests).
            let registry = PluginRegistry()
            coordinator.pluginRegistry = registry

            let list: [AppCoordinator.AgentPluginEntry] = coordinator.agentPluginList()

            // echo is DEBUG-registered but must be filtered out.
            #expect(!list.contains(where: { $0.id == EchoPluginCore.pluginID }))

            // claude-code and codex are always registered; check both are present.
            let ids = list.map(\.id)
            #expect(ids.contains("claude-code"))
            #expect(ids.contains("codex"))

            // IDs must be sorted (registeredIDs is sorted; filter preserves order).
            #expect(ids == ids.sorted())

            // Names come from the manifest's displayName field.
            let claudeRow = list.first { $0.id == "claude-code" }
            #expect(claudeRow?.name == "Claude Code")
        }
    }
#endif
