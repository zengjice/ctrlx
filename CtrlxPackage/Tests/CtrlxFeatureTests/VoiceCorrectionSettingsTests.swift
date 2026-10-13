#if os(iOS)
    import ConcurrencyExtras
    import CtrlxCommon
    import CtrlxEncryption
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxFeature

    @Suite("Voice correction credential settings")
    @MainActor
    struct VoiceCorrectionSettingsTests {
        @Test("Load the saved key without overwriting a draft on subsequent preparation")
        func savedKeyAndDraft() async throws {
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
            } operation: {
                @Dependency(SecretsService.self) var secrets
                let settings = IOSSettings()
                let account = VoiceCorrectionCredentials.apiKeyAccount(for: settings.voiceCorrectionProvider)
                try await secrets.storeSecret("saved-fixture-key", account)
                let model = VoiceCorrectionSettingsModel()

                await model.prepare(settings: settings)
                #expect(model.apiKeyDraft == "saved-fixture-key")
                #expect(model.hasStoredAPIKey)
                model.apiKeyDraft = "replacement-draft"
                await model.prepare(settings: settings)
                #expect(model.apiKeyDraft == "replacement-draft")
                #expect(try await secrets.loadSecret(account) == "saved-fixture-key")
            }
        }

        @Test("Saving and removing update both the displayed key and Keychain")
        func saveAndRemove() async throws {
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
            } operation: {
                @Dependency(SecretsService.self) var secrets
                let settings = IOSSettings()
                let account = VoiceCorrectionCredentials.apiKeyAccount(for: settings.voiceCorrectionProvider)
                let model = VoiceCorrectionSettingsModel()
                await model.prepare(settings: settings)

                #expect(model.apiKeyDraft.isEmpty)
                #expect(!model.hasStoredAPIKey)
                model.apiKeyDraft = "  saved-fixture-key  "
                await model.saveAPIKey(settings: settings)
                #expect(model.apiKeyDraft == "saved-fixture-key")
                #expect(model.hasStoredAPIKey)
                let savedKey = try await secrets.loadSecret(account)
                #expect(savedKey == "saved-fixture-key")

                await model.removeAPIKey(settings: settings)
                #expect(model.apiKeyDraft.isEmpty)
                #expect(!model.hasStoredAPIKey)
                let removedKey = try await secrets.loadSecret(account)
                #expect(removedKey == nil)
            }
        }

        @Test("A cancelled read leaves the key hidden and can be retried when settings reopen")
        func cancelledReadCanReload() async {
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let shouldWait = LockIsolated(true)
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                var secrets = SecretsService.inMemory()
                secrets.loadSecret = { _ in
                    let wait = shouldWait.withValue { value in
                        defer { value = false }
                        return value
                    }
                    if wait {
                        entered.continuation.yield(())
                        for await _ in release.stream {
                            break
                        }
                    }
                    return "saved-fixture-key"
                }
                $0[SecretsService.self] = secrets
            } operation: {
                let settings = IOSSettings()
                let model = VoiceCorrectionSettingsModel()
                let pending = Task { await model.prepare(settings: settings) }
                for await _ in entered.stream {
                    break
                }

                pending.cancel()
                await pending.value
                release.continuation.finish()
                #expect(model.apiKeyDraft.isEmpty)
                #expect(!model.hasStoredAPIKey)
                await model.prepare(settings: settings)
                #expect(model.apiKeyDraft == "saved-fixture-key")
                #expect(model.hasStoredAPIKey)
            }
        }
    }
#endif
