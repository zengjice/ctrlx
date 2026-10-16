#if os(iOS) || os(macOS)
    import CtrlxEncryption
    import Dependencies
    import Foundation
    import Observation

    @Observable
    @MainActor
    final class VoiceCorrectionSettingsModel {
        enum CredentialStatus: Equatable {
            case checking
            case missing
            case saved
            case unreadable

            var label: String {
                switch self {
                case .checking: "Checking API key…"
                case .missing: "Not configured — save an API key on this device"
                case .saved: "Configured — API key saved, access not verified"
                case .unreadable: "Unavailable — could not read API key"
                }
            }
        }

        var apiKeyDraft = ""
        var topModelCount = 5
        private(set) var models: [String] = []
        private(set) var testResults: [VoiceCorrectionModelTestResult] = []
        private(set) var credentialStatus: CredentialStatus = .checking
        private(set) var onDeviceAvailability: VoiceCorrectionAvailability?
        var hasStoredAPIKey: Bool {
            credentialStatus == .saved
        }

        private(set) var hasTestedModels = false
        private(set) var isLoading = false
        private(set) var isTesting = false
        private(set) var testedModelCount = 0
        private(set) var totalModelCount = 0
        private(set) var statusMessage: String?
        private(set) var errorMessage: String?

        @ObservationIgnored
        @Dependency(SecretsService.self) private var secrets
        @ObservationIgnored
        @Dependency(VoiceCorrectionAvailabilityClient.self) private var availability

        @ObservationIgnored private let client: VoiceCorrectionProviderClient

        @ObservationIgnored private var preparedProvider: VoiceCorrectionProvider?

        var isBusy: Bool {
            isLoading || isTesting
        }

        var eligibleResults: [VoiceCorrectionModelTestResult] {
            testResults.filter(\.isEligible)
        }

        var testProgressText: String {
            guard totalModelCount > 0 else { return "Testing Models" }
            return "Testing \(testedModelCount) of \(totalModelCount)"
        }

        init(client: VoiceCorrectionProviderClient = VoiceCorrectionProviderClient()) {
            self.client = client
        }

        func prepare(settings: VoiceCorrectionSettings) async {
            guard !isBusy else { return }
            onDeviceAvailability = availability.onDevice(settings.language.localeIdentifier)
            let provider = settings.provider
            let providerChanged = preparedProvider != provider
            if providerChanged {
                apiKeyDraft = ""
                credentialStatus = .checking
                clearMessages()
                testResults = []
                testedModelCount = 0
                totalModelCount = 0
                topModelCount = provider.recommendedModelIDs.count
            }
            applySavedOrRecommendedModels(settings: settings)
            let account = VoiceCorrectionCredentials.apiKeyAccount(
                for: provider
            )
            do {
                let savedKey = try await secrets.loadSecret(account)
                guard !Task.isCancelled, settings.provider == provider else { return }
                if credentialStatus == .unreadable {
                    errorMessage = nil
                }
                credentialStatus = savedKey?.isEmpty == false ? .saved : .missing
                if providerChanged, apiKeyDraft.isEmpty {
                    apiKeyDraft = savedKey ?? ""
                }
                preparedProvider = provider
            } catch {
                guard !Task.isCancelled, settings.provider == provider else { return }
                credentialStatus = .unreadable
                errorMessage = error.localizedDescription
            }
        }

        func saveAPIKey(settings: VoiceCorrectionSettings) async {
            guard !isLoading else { return }
            clearMessages()
            isLoading = true
            defer { isLoading = false }

            let provider = settings.provider
            let account = VoiceCorrectionCredentials.apiKeyAccount(
                for: provider
            )
            do {
                let keyDraft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyDraft.isEmpty else {
                    errorMessage = "Enter an API key first."
                    return
                }

                try await secrets.storeSecret(keyDraft, account)
                apiKeyDraft = keyDraft
                credentialStatus = .saved
                applySavedOrRecommendedModels(settings: settings)
                statusMessage = "API key saved."
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func testModels(settings: VoiceCorrectionSettings) async {
            guard !isBusy else { return }
            clearMessages()
            isTesting = true
            testedModelCount = 0
            totalModelCount = 0
            testResults = []
            defer {
                isTesting = false
                if Task.isCancelled {
                    statusMessage = "Model test cancelled."
                }
            }

            let provider = settings.provider
            let account = VoiceCorrectionCredentials.apiKeyAccount(for: provider)
            do {
                guard let apiKey = try await secrets.loadSecret(account), !apiKey.isEmpty else {
                    credentialStatus = .missing
                    errorMessage = "Save an API key before testing models."
                    return
                }

                try Task.checkCancellation()
                let availableModelIDs = try await client.fetchModels(
                    provider: provider,
                    apiKey: apiKey
                )
                try Task.checkCancellation()
                let candidateModelIDs = VoiceCorrectionBenchmark.candidateModelIDs(
                    for: provider,
                    from: availableModelIDs,
                    selectedModelID: settings.modelID
                )
                guard !candidateModelIDs.isEmpty else {
                    errorMessage = "No supported text models are available for this provider."
                    return
                }

                totalModelCount = candidateModelIDs.count
                var completedResults: [VoiceCorrectionModelTestResult] = []
                var failedModelCount = 0
                for modelID in candidateModelIDs {
                    guard !Task.isCancelled else {
                        statusMessage = "Model test cancelled."
                        return
                    }
                    do {
                        let result = try await VoiceCorrectionBenchmark.evaluate(
                            modelID: modelID,
                            provider: provider,
                            apiKey: apiKey,
                            client: client
                        )
                        try Task.checkCancellation()
                        completedResults.append(result)
                        testResults = VoiceCorrectionBenchmark.ranked(completedResults)
                    } catch {
                        if Task.isCancelled {
                            return
                        }
                        failedModelCount += 1
                    }
                    testedModelCount += 1
                }

                guard !testResults.isEmpty else {
                    errorMessage = "Every model test failed. Check the API key and try again."
                    return
                }
                topModelCount = max(1, min(provider.recommendedModelIDs.count, eligibleResults.count))
                statusMessage = failedModelCount == 0
                    ? "Tested \(testResults.count) models; \(eligibleResults.count) passed every critical check."
                    : "Tested \(totalModelCount) models; \(failedModelCount) failed."
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }

        func saveTopModels(settings: VoiceCorrectionSettings) {
            clearMessages()
            guard !isBusy, !eligibleResults.isEmpty else { return }
            let count = min(max(1, topModelCount), eligibleResults.count)
            let modelIDs = eligibleResults.prefix(count).map(\.modelID)
            settings.saveTestedModelIDs(
                modelIDs,
                for: settings.provider
            )
            models = modelIDs
            hasTestedModels = true
            settings.modelID = modelIDs[0]
            statusMessage = "Saved the top \(count) tested models."
        }

        func restoreRecommendedModels(settings: VoiceCorrectionSettings) {
            clearMessages()
            settings.resetTestedModels(for: settings.provider)
            applySavedOrRecommendedModels(settings: settings)
            statusMessage = "Restored the built-in recommended models."
        }

        func removeAPIKey(settings: VoiceCorrectionSettings) async {
            guard !isLoading else { return }
            clearMessages()
            isLoading = true
            defer { isLoading = false }

            let account = VoiceCorrectionCredentials.apiKeyAccount(
                for: settings.provider
            )
            do {
                try await secrets.deleteSecret(account)
                apiKeyDraft = ""
                credentialStatus = .missing
                statusMessage = "API key removed."
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        private func clearMessages() {
            statusMessage = nil
            errorMessage = nil
        }

        private func applySavedOrRecommendedModels(settings: VoiceCorrectionSettings) {
            let provider = settings.provider
            models = settings.modelIDs(for: provider)
            hasTestedModels = settings.hasTestedModels(for: provider)
            if !models.contains(settings.modelID) {
                settings.modelID = models.first ?? ""
            }
        }
    }
#endif
