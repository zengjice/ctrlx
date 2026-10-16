import Testing
@testable import CtrlxCommon

@Suite("Voice transcript fidelity")
struct VoiceTranscriptFidelityTests {
    @Test("Rejects lost negation, conditions, clauses and unquoted code")
    func unsafeCorrections() {
        let examples = [
            ("只检查，不要提交，也不要发布。", "检查后提交并发布。"),
            ("除非测试通过，否则不要发布。", "测试通过就发布。"),
            ("先检查编译结果，再检查键盘弹出和收起，最后验证语音输入及所有端的自动排序。", "先检查编译结果。"),
            ("只检查 git status 和 feature/voice-input 分支。", "只检查 git reset 和 feature/voice-fix 分支。"),
            ("不要提交，可以发布。", "不要发布，可以提交。"),
            ("没跑测试，不要提交。", "跑测试，不要提交。"),
            ("I haven't tested; don't deploy.", "I have tested; don't deploy."),
        ]
        for (source, candidate) in examples {
            #expect(VoiceTranscriptCorrectionPolicy.accepted(candidate, replacing: source) == source)
        }
    }

    @Test("Allows homophone correction and punctuation without forcing domain replacements")
    func usefulCorrections() {
        let examples = [
            ("将本地妹分支合入", "将本地 main 分支合入"),
            ("这个绘画列表应该自适应", "这个会话列表应该自适应"),
            ("不要提交先检查语音书入", "不要提交，先检查语音输入。"),
            ("绘画作品已经完成", "绘画作品已经完成。"),
        ]
        for (source, candidate) in examples {
            #expect(VoiceTranscriptCorrectionPolicy.accepted(candidate, replacing: source) == candidate)
        }
    }

    @Test("Accurate pass cannot silently discard live clauses or negation")
    func incompleteAccuratePass() {
        let live = "先检查编译结果。再修复输入框中的光标位置。最后验证键盘收起行为。"
        let result = VoiceRecognitionResult(primaryTranscript: "先检查编译结果。", liveTranscript: live)
        #expect(result.bestAvailableTranscript == live)
        #expect(result.primaryTranscript == "先检查编译结果。")
        let negation = VoiceRecognitionResult(primaryTranscript: "检查后提交。", liveTranscript: "只检查，不要提交。")
        #expect(negation.bestAvailableTranscript == negation.liveTranscript)
    }

    @Test("Accurate pass still removes repetitions and corrects names")
    func notSimplyLongest() {
        let repetition = VoiceRecognitionResult(primaryTranscript: "检查编译结果。", liveTranscript: "检查编译结果，检查编译结果，检查编译结果。")
        #expect(repetition.bestAvailableTranscript == repetition.primaryTranscript)
        let corrected = VoiceRecognitionResult(primaryTranscript: "CtrlX 语音输入。", liveTranscript: "CTRS 语音书入。")
        #expect(corrected.bestAvailableTranscript == corrected.primaryTranscript)
    }

    @Test("A critical failure ranks below every eligible model regardless of total score")
    func rankingGate() {
        let unsafe = VoiceCorrectionModelTestResult(
            modelID: "unsafe",
            score: 390,
            maximumScore: 450,
            requiredTermHits: 44,
            rejectedTermHits: 0,
            elapsedSeconds: 1,
            sampleCount: 13,
            failedCriticalSampleIDs: ["negation-and-condition"]
        )
        let safe = VoiceCorrectionModelTestResult(
            modelID: "safe",
            score: 275,
            maximumScore: 450,
            requiredTermHits: 28,
            rejectedTermHits: 1,
            elapsedSeconds: 10,
            sampleCount: 13
        )
        #expect(VoiceCorrectionBenchmark.ranked([unsafe, safe]).map(\.modelID) == ["safe", "unsafe"])
        for id in ["negation-and-condition", "numbers-and-literals", "long-utterance-completeness"] {
            #expect(VoiceCorrectionBenchmark.samples.first { $0.id == id }?.isCritical == true)
        }
    }
}
