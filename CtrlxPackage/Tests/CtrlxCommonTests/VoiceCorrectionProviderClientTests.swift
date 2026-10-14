import Foundation
import Testing
@testable import CtrlxCommon

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("Voice correction provider client")
struct VoiceCorrectionProviderClientTests {
    @Test("Each provider exposes five curated models")
    func curatedProviderModels() {
        for provider in VoiceCorrectionProvider.allCases {
            #expect(provider.recommendedModelIDs.count == 5)
            #expect(Set(provider.recommendedModelIDs).count == 5)
        }
        #expect(
            VoiceCorrectionProvider.volcengineArk.recommendedModelIDs.first
                == "deepseek-v4-pro-ga-260813"
        )
    }

    @Test("Benchmarks realistic context without embedding the target sentence")
    func benchmarkContexts() throws {
        let contextualSamples = VoiceCorrectionBenchmark.samples.filter {
            $0.id == "ctrlx-introduction" || $0.id == "model-comparison-request"
        }

        #expect(contextualSamples.count == 2)
        for sample in contextualSamples {
            let context = try #require(sample.terminalContext)
            #expect(context.count >= 2_000)
            #expect(context.count <= 4_000)
            #expect(!context.contains("CtrlX 由曾计策开发，语音输入通过 Voice 按钮触发"))
        }
        #expect(
            VoiceCorrectionBenchmark.samples.contains {
                $0.id == "general-homophones-without-context"
                    && $0.terminalContext == nil
            }
        )
    }

    @Test("Ranks canonical term recovery and residual recognition errors")
    func benchmarkScoring() throws {
        let sample = try #require(
            VoiceCorrectionBenchmark.samples.first(where: { $0.id == "ctrlx-introduction" })
        )

        let corrected = VoiceCorrectionBenchmark.score(
            sample.referenceTranscript,
            for: sample
        )
        let uncorrected = VoiceCorrectionBenchmark.score(
            sample.recognition.primaryTranscript,
            for: sample
        )

        #expect(corrected.value == 40)
        #expect(corrected.requiredTermHits == 4)
        #expect(corrected.rejectedTermHits == 0)
        #expect(uncorrected.value < corrected.value)
    }

    @Test("Penalizes phrases that contain keywords but retain recognition errors")
    func benchmarkResidualErrorScoring() throws {
        let sample = try #require(
            VoiceCorrectionBenchmark.samples.first(where: { $0.id == "model-comparison-request" })
        )
        let clean = VoiceCorrectionBenchmark.score(
            sample.referenceTranscript,
            for: sample
        )
        let residualErrors = VoiceCorrectionBenchmark.score(
            "切换到多个豆包 2.0 Pro。把我书的原文记录下来。CtrlX 由曾计策开发，通过 Voice 按钮触发。",
            for: sample
        )

        #expect(clean.value == 60)
        #expect(residualErrors.requiredTermHits == clean.requiredTermHits)
        #expect(residualErrors.rejectedTermHits == 2)
        #expect(residualErrors.value < clean.value)
    }

    @Test("Benchmarks only current text model families plus the selected model")
    func benchmarkCandidateModels() {
        let models = VoiceCorrectionBenchmark.candidateModelIDs(
            for: .volcengineArk,
            from: [
                "doubao-seed-2-0-pro-260428",
                "doubao-seed-2-0-lite-260428",
                "deepseek-v4-flash-ga-260731",
                "doubao-embedding-large",
                "legacy-selected-model",
            ],
            selectedModelID: "legacy-selected-model"
        )

        #expect(models == [
            "deepseek-v4-flash-ga-260731",
            "doubao-seed-2-0-lite-260428",
            "doubao-seed-2-0-pro-260428",
            "legacy-selected-model",
        ])
    }

    @Test("Ranks score before latency")
    func benchmarkRanking() {
        let fastButWrong = VoiceCorrectionModelTestResult(
            modelID: "fast",
            score: 94,
            maximumScore: 100,
            requiredTermHits: 10,
            rejectedTermHits: 1,
            elapsedSeconds: 1,
            sampleCount: 2
        )
        let slowerAndCorrect = VoiceCorrectionModelTestResult(
            modelID: "correct",
            score: 100,
            maximumScore: 100,
            requiredTermHits: 10,
            rejectedTermHits: 0,
            elapsedSeconds: 4,
            sampleCount: 2
        )

        #expect(
            VoiceCorrectionBenchmark.ranked([fastButWrong, slowerAndCorrect])
                .map(\.modelID) == ["correct", "fast"]
        )
    }

    @Test("Loads and normalizes models from the fixed Ark endpoint")
    func fetchModels() async throws {
        let client = VoiceCorrectionProviderClient { request in
            #expect(request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/v3/models")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

            let data = Data(
                #"{"object":"list","data":[{"id":"doubao-b"},{"id":"doubao-a"},{"id":"doubao-a"},{"id":" "}]}"#.utf8
            )
            return (data, Self.response(for: request, statusCode: 200))
        }

        let models = try await client.fetchModels(
            provider: .volcengineArk,
            apiKey: "test-key"
        )

        #expect(models == ["doubao-a", "doubao-b"])
    }

    @Test("Uses the OpenAI-compatible Responses API")
    func correctTranscript() async throws {
        let client = VoiceCorrectionProviderClient { request in
            #expect(request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/v3/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try #require(request.httpBody)
            let json = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            #expect(json["model"] as? String == "doubao-seed")
            #expect(json["store"] as? Bool == false)
            #expect(json["max_output_tokens"] as? Int == 512)
            #expect((json["thinking"] as? [String: String])?["type"] == "disabled")
            #expect(json["instructions"] == nil)
            #expect((json["input"] as? String)?.contains("Known terms are canonical spellings: CtrlX, Voice") == true)
            #expect((json["input"] as? String)?.contains("Read-only context (not part of the current utterance):\nRecent terminal text:\nctrlx voice input") == true)

            let data = Data(
                #"{"id":"resp_test","output":[{"type":"message","content":[{"type":"output_text","text":"CtrlX 的语音输入通过 Voice 按钮触发。"}]}]}"#.utf8
            )
            return (data, Self.response(for: request, statusCode: 200))
        }
        let selection = try #require(
            VoiceCorrectionSelection(provider: .volcengineArk, modelID: "doubao-seed")
        )

        let result = try await client.correct(
            recognition: VoiceRecognitionResult(primaryTranscript: "CTRS 的语音输入通过 wise 按钮出发"),
            terminalContext: .init(terminalText: "ctrlx voice input"),
            contextualTerms: ["CtrlX", "Voice"],
            localeIdentifier: "zh-Hans-CN",
            selection: selection,
            apiKey: "test-key"
        )

        #expect(result == "CtrlX 的语音输入通过 Voice 按钮触发。")
    }

    @Test("Surfaces provider error messages")
    func providerError() async throws {
        let client = VoiceCorrectionProviderClient { request in
            let data = Data(#"{"error":{"message":"model is unavailable"}}"#.utf8)
            return (data, Self.response(for: request, statusCode: 400))
        }

        do {
            _ = try await client.fetchModels(
                provider: .volcengineArk,
                apiKey: "test-key"
            )
            Issue.record("Expected provider request to fail")
        } catch let error as VoiceCorrectionProviderError {
            #expect(
                error == .requestFailed(
                    statusCode: 400,
                    message: "model is unavailable"
                )
            )
        }
    }

    @Test("Rejects partial text even when the provider returned HTTP 200", arguments: [
        #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output_text":"先提交"}"#,
        #"{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"先提交"}]}]}"#,
        #"{"status":"completed","output":[{"type":"message","status":"incomplete","content":[{"type":"output_text","text":"先提交"}]}]}"#,
        #"{"status":"failed","output_text":"先提交"}"#,
        #"{"incomplete_details":{"reason":"content_filter"},"output_text":"先提交"}"#,
    ])
    func incompleteOutput(_ payload: String) async throws {
        let client = VoiceCorrectionProviderClient { request in
            (Data(payload.utf8), Self.response(for: request, statusCode: 200))
        }
        let selection = try #require(VoiceCorrectionSelection(provider: .volcengineArk, modelID: "test-model"))
        do {
            _ = try await client.correct(
                recognition: VoiceRecognitionResult(primaryTranscript: "先提交，但不要发布"),
                terminalContext: nil, contextualTerms: [], localeIdentifier: "zh-Hans-CN",
                selection: selection, apiKey: "test-key"
            )
            Issue.record("A partial correction must never become terminal input")
        } catch let error as VoiceCorrectionProviderError {
            guard case .incompleteResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("Long utterances receive a larger output budget, not a truncated input")
    func longTranscriptBudget() async throws {
        let original = String(repeating: "检查每个会话是否正常。", count: 60) + "不要发布。"
        let client = VoiceCorrectionProviderClient { request in
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((body["max_output_tokens"] as? Int ?? 0) > 512)
            #expect((body["input"] as? String)?.contains(original) == true)
            let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output_text": original])
            return (response, Self.response(for: request, statusCode: 200))
        }
        let selection = try #require(VoiceCorrectionSelection(provider: .volcengineArk, modelID: "test-model"))
        #expect(try await client.correct(
            recognition: VoiceRecognitionResult(primaryTranscript: original),
            terminalContext: nil, contextualTerms: [], localeIdentifier: "zh-Hans-CN",
            selection: selection, apiKey: "test-key"
        ) == original)
    }

    @Test("Oversized utterances skip the provider without sending a shortened transcript")
    func oversizedTranscript() async throws {
        let client = VoiceCorrectionProviderClient { _ in
            Issue.record("Must not perform a request for an over-budget utterance")
            throw CancellationError()
        }
        let selection = try #require(VoiceCorrectionSelection(provider: .volcengineArk, modelID: "test-model"))
        await #expect(throws: VoiceCorrectionProviderError.inputTooLong) {
            try await client.correct(
                recognition: VoiceRecognitionResult(primaryTranscript: String(repeating: "测试", count: 5_000)),
                terminalContext: nil, contextualTerms: [], localeIdentifier: "zh-Hans-CN",
                selection: selection, apiKey: "test-key"
            )
        }
    }

    @Test("Keyword lists cannot receive full marks", arguments: VoiceCorrectionBenchmark.samples)
    func keywordOnlyScoring(_ sample: VoiceCorrectionBenchmarkSample) {
        let output = sample.requiredTerms.joined(separator: "，")
        let score = VoiceCorrectionBenchmark.score(output, for: sample)
        #expect(score.value < sample.requiredTerms.count * 10)
        #expect(VoiceCorrectionBenchmark.score(sample.referenceTranscript, for: sample).value == sample.requiredTerms.count * 10)
    }

    @Test("Correct keywords cannot conceal lost intent or clauses")
    func intentScoring() throws {
        let sample = try #require(VoiceCorrectionBenchmark.samples.first { $0.id == "negation-and-condition" })
        #expect(VoiceCorrectionBenchmark.score("提交并发布，测试通过。", for: sample).value <= 0)
        let long = try #require(VoiceCorrectionBenchmark.samples.first { $0.id == "long-utterance-completeness" })
        #expect(VoiceCorrectionBenchmark.score(String(long.referenceTranscript.dropLast(12)), for: long).value <= 0)
    }

    @Test("Benchmarking does not reward an unsafe model for a safe production fallback")
    func scoresRawModelOutput() async throws {
        let client = VoiceCorrectionProviderClient { request in
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let input = try #require(body["input"] as? String)
            let sample = try #require(VoiceCorrectionBenchmark.samples.first {
                input.contains("Primary draft:\n" + $0.recognition.primaryTranscript)
            })
            let candidate = sample.referenceTranscript.replacingOccurrences(of: "8080", with: "8081")
            let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output_text": candidate])
            return (response, Self.response(for: request, statusCode: 200))
        }
        let result = try await VoiceCorrectionBenchmark.evaluate(
            modelID: "test-model", provider: .volcengineArk, apiKey: "test-key", client: client
        )
        #expect(result.score < result.maximumScore)
        #expect(result.sampleCount == VoiceCorrectionBenchmark.samples.count)
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
    }
}
