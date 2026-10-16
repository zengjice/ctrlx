import ConcurrencyExtras
import CtrlxEncryption
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Voice correction benchmark lifetime")
struct VoiceCorrectionCancellationTests {
    @Test("Cancelling the settings task cancels transport and never starts another sample")
    func cancellation() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let calls = LockIsolated(0)
        let cancelled = LockIsolated(false)
        let client = VoiceCorrectionProviderClient { request in
            if request.httpMethod == "GET" {
                return Self.response(#"{"data":[{"id":"deepseek-v4-fixture"}]}"#, request: request)
            }
            calls.withValue { $0 += 1 }
            entered.continuation.yield(())
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
            } onCancel: { cancelled.setValue(true) }
            return Self.response(#"{"output_text":"unexpected"}"#, request: request)
        }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
        } operation: {
            @Dependency(SecretsService.self) var secrets
            let settings = VoiceCorrectionSettings()
            try await secrets.storeSecret("fixture-key", VoiceCorrectionCredentials.apiKeyAccount(for: settings.provider))
            let model = VoiceCorrectionSettingsModel(client: client)
            let task = Task { await model.testModels(settings: settings) }
            for await _ in entered.stream {
                break
            }
            task.cancel()
            await task.value
            #expect(cancelled.value)
            #expect(calls.value == 1)
            #expect(!model.isTesting)
            #expect(model.testResults.isEmpty)
            #expect(model.errorMessage == nil)
            #expect(model.statusMessage == "Model test cancelled.")
        }
        entered.continuation.finish()
    }

    @Test("A completed model failing one critical case cannot be saved as a winner")
    func failedCriticalModelCannotBeSaved() async throws {
        let index = LockIsolated(0)
        let client = VoiceCorrectionProviderClient { request in
            if request.httpMethod == "GET" {
                return Self.response(#"{"data":[{"id":"deepseek-v4-fixture"}]}"#, request: request)
            }
            let sample = index.withValue { value in
                defer { value += 1 }
                return VoiceCorrectionBenchmark.samples[value]
            }
            let text = sample.id == "negation-and-condition" ? "检查后提交并发布。" : sample.referenceTranscript
            let data = try JSONEncoder().encode(["output_text": text])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
        } operation: {
            @Dependency(SecretsService.self) var secrets
            let settings = VoiceCorrectionSettings()
            try await secrets.storeSecret("fixture-key", VoiceCorrectionCredentials.apiKeyAccount(for: settings.provider))
            let model = VoiceCorrectionSettingsModel(client: client)
            await model.testModels(settings: settings)
            #expect(model.testResults.count == 1)
            #expect(model.testResults.first?.failedCriticalSampleIDs.contains("negation-and-condition") == true)
            #expect(model.eligibleResults.isEmpty)
            model.saveTopModels(settings: settings)
            #expect(!settings.hasTestedModels(for: settings.provider))
            #expect(settings.modelID.isEmpty)
        }
    }

    private nonisolated static func response(_ json: String, request: URLRequest) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
