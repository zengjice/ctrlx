#if os(iOS) || os(macOS)
    import ConcurrencyExtras
    import CtrlxEncryption
    import Dependencies
    import Foundation
    import Testing
    @testable import CtrlxCommon

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
                let settings = VoiceCorrectionSettings()
                let account = VoiceCorrectionCredentials.apiKeyAccount(for: settings.provider)
                try await secrets.storeSecret("saved-fixture-key", account)
                let model = VoiceCorrectionSettingsModel()

                await model.prepare(settings: settings)
                #expect(model.apiKeyDraft == "saved-fixture-key")
                #expect(model.hasStoredAPIKey)
                #expect(model.credentialStatus == .saved)
                #expect(model.credentialStatus.label.contains("not verified"))
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
                let settings = VoiceCorrectionSettings()
                let account = VoiceCorrectionCredentials.apiKeyAccount(for: settings.provider)
                let model = VoiceCorrectionSettingsModel()
                await model.prepare(settings: settings)

                #expect(model.apiKeyDraft.isEmpty)
                #expect(!model.hasStoredAPIKey)
                #expect(model.credentialStatus == .missing)
                model.apiKeyDraft = "  saved-fixture-key  "
                await model.saveAPIKey(settings: settings)
                #expect(model.apiKeyDraft == "saved-fixture-key")
                #expect(model.hasStoredAPIKey)
                #expect(model.credentialStatus == .saved)
                let savedKey = try await secrets.loadSecret(account)
                #expect(savedKey == "saved-fixture-key")

                await model.removeAPIKey(settings: settings)
                #expect(model.apiKeyDraft.isEmpty)
                #expect(!model.hasStoredAPIKey)
                #expect(model.credentialStatus == .missing)
                let removedKey = try await secrets.loadSecret(account)
                #expect(removedKey == nil)
            }
        }

        @Test("Settings refresh on-device availability and distinguish unreadable credentials from missing ones")
        func availabilityAndReadFailure() async {
            let status = LockIsolated(VoiceCorrectionAvailability.unavailable("Apple Intelligence is not enabled"))
            let readFails = LockIsolated(true)
            await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                var secrets = SecretsService.inMemory()
                secrets.loadSecret = { _ in
                    if readFails.value {
                        throw CocoaError(.fileReadNoPermission)
                    }
                    return "saved-fixture-key"
                }
                $0[SecretsService.self] = secrets
                $0[VoiceCorrectionAvailabilityClient.self] = .init(onDevice: { status.value })
            } operation: {
                let settings = VoiceCorrectionSettings()
                let model = VoiceCorrectionSettingsModel()
                #expect(model.credentialStatus == .checking)
                await model.prepare(settings: settings)
                #expect(model.credentialStatus == .unreadable)
                #expect(!model.hasStoredAPIKey)
                #expect(model.onDeviceAvailability == status.value)
                status.setValue(.available)
                readFails.setValue(false)
                await model.prepare(settings: settings)
                #expect(model.onDeviceAvailability == .available)
                #expect(model.credentialStatus == .saved)
                #expect(model.errorMessage == nil)
            }
        }

        @Test("A selected model without a key and without Apple Intelligence returns an explicit uncorrected result")
        func missingKeyAndUnavailableDevice() async throws {
            try await withDependencies {
                $0[PreferencesService.self] = .inMemory()
                $0[SecretsService.self] = .inMemory()
                $0[VoiceCorrectionAvailabilityClient.self] = .init(onDevice: { .unavailable("Device not supported") })
            } operation: {
                let settings = VoiceCorrectionSettings()
                let model = VoiceCorrectionSettingsModel()
                await model.prepare(settings: settings)
                let selection = try #require(settings.selection)
                #expect(model.credentialStatus == .missing)
                #expect(model.onDeviceAvailability?.isAvailable == false)
                let result = await VoiceTranscriptCorrector.correct(
                    "绑定服用", contextualTerms: ["pane"],
                    terminalContext: .init(terminalText: "绑定 pane 复用"), providerSelection: selection
                )
                #expect(result.text == "绑定服用")
                #expect(result.outcome == .unavailable)
                #expect(result.notice != nil)
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
                let settings = VoiceCorrectionSettings()
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
