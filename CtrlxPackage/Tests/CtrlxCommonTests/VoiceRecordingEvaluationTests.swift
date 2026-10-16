import CtrlxEncryption
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Recorded voice evaluation", .serialized)
struct VoiceRecordingEvaluationTests {
    @Test("Progressive file replay does not append volatile revisions as duplicate speech")
    func progressiveSegments() {
        var accumulator = VoiceRecognitionCandidateAccumulator()
        accumulator.append(primary: "检查", alternatives: [], isFinal: false)
        accumulator.append(primary: "检查会话", alternatives: [], isFinal: false)
        accumulator.append(primary: "检查会话列表。", alternatives: [], isFinal: true)
        accumulator.append(primary: "不要", alternatives: [], isFinal: false)
        accumulator.append(primary: "不要提交。", alternatives: [], isFinal: true)
        let result = accumulator.makeResult(liveTranscript: "", diagnosticID: "fixture")
        #expect(result.primaryTranscript == "检查会话列表。不要提交。")
    }

    @Test("Same recording and locale feed both passes; correction is opt-in")
    func sameRecording() async throws {
        try await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: {
                Issue.record("File evaluation must not request microphone access")
                return false
            })
        } operation: {
            let file = URL(fileURLWithPath: "/fixture.caf")
            let reference = "先检查 CtrlX 会话列表。然后验证标签页切换和自动排序。不要提交。"
            var passes: [Bool] = []
            let report = try await VoiceRecordingEvaluation.run(
                file: file,
                reference: reference,
                localeIdentifier: "zh-Hans-CN",
                selection: VoiceCorrectionSelection(provider: .volcengineArk, modelID: "cloud-model"),
                recognize: { url, locale, terms, accurate, live in
                    #expect(url == file)
                    #expect(locale == "zh-Hans-CN")
                    #expect(terms.contains("会话"))
                    passes.append(accurate)
                    if accurate {
                        #expect(live == reference)
                        return .init(primaryTranscript: "先检查 CtrlX 会话列表。")
                    }
                    return .init(primaryTranscript: reference)
                },
                correct: { _, _, _, _ in
                    Issue.record("Correction must be explicitly enabled")
                    return .init(text: "", outcome: .unavailable)
                }
            )
            #expect(passes == [false, true])
            #expect(report.usedLiveFallback)
            #expect(report.correctionOutcome == "notRun")
            #expect(report.configuredCorrectionModel == nil)
            #expect(report.correctionModel == nil)
            #expect(!report.correctionDidFallback)
            #expect(report.stages.count == 3)
            #expect(report.stages[1].unmatchedReferenceCharacters > 0)
            #expect(!report.stages[1].preservesIntentMarkers)
            #expect(report.stages[2].transcript == reference)
            let decoded = try JSONDecoder().decode(VoiceRecordingEvaluationReport.self, from: report.json())
            #expect(decoded.stages[0].transcript == reference)
            #expect(decoded.audioFileName == "fixture.caf")
        }
    }

    @Test("Report and JSON attribute candidates to their actual model, including fallback", arguments: [
        VoiceCorrectionAttempt.accepted("不要提交。"),
        .unavailable,
        .rejected(.changedIntent),
    ])
    func correctionModelAttribution(_ providerOutcome: VoiceCorrectionAttempt) async throws {
        try await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { false })
        } operation: {
            let reference = "不要提交。"
            let report = try await VoiceRecordingEvaluation.run(
                file: URL(fileURLWithPath: "/fixture.caf"),
                reference: reference,
                localeIdentifier: "zh-Hans-CN",
                includeCorrection: true,
                selection: VoiceCorrectionSelection(provider: .volcengineArk, modelID: "cloud-model"),
                recognize: { _, _, _, _, _ in .init(primaryTranscript: reference) },
                correct: { recognition, _, _, selection in
                    await VoiceTranscriptCorrectionRouting.run(
                        original: recognition.bestAvailableTranscript, providerModelID: selection?.modelID
                    ) { route in
                        route == .provider ? providerOutcome : .accepted(reference)
                    }
                }
            )
            let decoded = try JSONDecoder().decode(VoiceRecordingEvaluationReport.self, from: report.json())
            for result in [report, decoded] {
                #expect(result.configuredCorrectionModel == "cloud-model")
                #expect(result.correctionModel == (providerOutcome == .unavailable ? "on-device" : "cloud-model"))
                #expect(result.correctionDidFallback == (providerOutcome == .unavailable))
                #expect(result.correctionOutcome == (providerOutcome == .rejected(.changedIntent) ? "rejected" : "accepted"))
                #expect(result.stages.last?.transcript == reference)
            }
        }
    }

    @Test("Missing key and unavailable device never attribute the original to the configured model")
    func unavailableCorrectionModel() async throws {
        try await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { false })
            $0[SecretsService.self] = .inMemory()
            $0[VoiceCorrectionAvailabilityClient.self] = .init(onDevice: { _ in .unavailable("Unavailable for test") })
        } operation: {
            let report = try await VoiceRecordingEvaluation.run(
                file: URL(fileURLWithPath: "/fixture.caf"),
                reference: "不要提交。",
                localeIdentifier: "zh-Hans-CN",
                includeCorrection: true,
                selection: VoiceCorrectionSelection(provider: .volcengineArk, modelID: "cloud-model"),
                recognize: { _, _, _, _, _ in .init(primaryTranscript: "不要提交。") }
            )
            let decoded = try JSONDecoder().decode(VoiceRecordingEvaluationReport.self, from: report.json())
            for result in [report, decoded] {
                #expect(result.configuredCorrectionModel == "cloud-model")
                #expect(result.correctionModel == nil)
                #expect(result.correctionDidFallback)
                #expect(result.correctionOutcome == "unavailable")
                #expect(result.stages.last?.transcript == "不要提交。")
            }
        }
    }

    @Test("Reports correction outcome separately from recognition and stops after cancellation")
    func correctionAndCancellation() async throws {
        try await withDependencies {
            $0[VoiceInputAuthorization.self] = .init(speech: { .authorized }, microphone: { false })
        } operation: {
            let reference = "不要提交。"
            let report = try await VoiceRecordingEvaluation.run(
                file: URL(fileURLWithPath: "/fixture.caf"),
                reference: reference,
                localeIdentifier: "zh-Hans-CN",
                includeCorrection: true,
                recognize: { _, _, _, _, _ in .init(primaryTranscript: reference) },
                correct: { recognition, _, _, _ in
                    #expect(recognition.localeIdentifier == "zh-Hans-CN")
                    return await VoiceTranscriptCorrectionRouting.run(
                        original: reference, providerModelID: nil
                    ) { _ in .rejected(.changedIntent) }
                }
            )
            #expect(report.correctionOutcome == "rejected")
            #expect(report.configuredCorrectionModel == "on-device")
            #expect(report.correctionModel == "on-device")
            #expect(!report.correctionDidFallback)
            #expect(report.stages.last?.transcript == reference)

            let entered = AsyncStream<Void>.makeStream()
            var calls = 0
            let task = Task {
                try await VoiceRecordingEvaluation.run(
                    file: URL(fileURLWithPath: "/fixture.caf"),
                    reference: reference,
                    localeIdentifier: "zh-Hans-CN",
                    includeCorrection: true,
                    recognize: { _, _, _, _, _ in
                        calls += 1
                        entered.continuation.yield(())
                        try await Task.sleep(for: .seconds(30))
                        return .init(primaryTranscript: reference)
                    }
                )
            }
            for await _ in entered.stream {
                break
            }
            task.cancel()
            do {
                _ = try await task.value
                Issue.record("Cancelled evaluation must not return a report")
            } catch is CancellationError {
                #expect(calls == 1)
            }
            entered.continuation.finish()
        }
    }
}
