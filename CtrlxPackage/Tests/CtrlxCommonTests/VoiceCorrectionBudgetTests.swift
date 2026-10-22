import Foundation
import Testing
@testable import CtrlxCommon

@Suite("Voice correction budgets and evidence")
struct VoiceCorrectionBudgetTests {
    @Test("Long utterances and production vocabulary still fit the legacy byte budget", arguments: [false, true])
    func legacyLongUtteranceBudget(withContext: Bool) async throws {
        let sample = try #require(VoiceCorrectionBenchmark.samples.first { $0.id == "long-utterance-completeness" })
        let original = sample.recognition.primaryTranscript
        #expect(original.count == 145)
        let context: VoiceInputContextSnapshot? = withContext ? .init(
            paneMetadata: ["Session: ctrlx", "Window: feature-bug", "Current path: /tmp/macinput"],
            terminalText: "oldest" + String(repeating: "unrelated log line\n", count: 1_000) + "newest"
        ) : nil
        let input = try #require(try await VoiceCorrectionBudget.onDeviceInput(
            recognition: sample.recognition,
            terminalContext: context, contextualTerms: VoiceInputVocabulary.terms(for: context),
            localeIdentifier: "zh-Hans-CN", contextSize: 4_096, countTokens: { $0.utf8.count }
        ))
        #expect(input.instructions.utf8.count + input.prompt.utf8.count + input.maximumResponseTokens + 128 <= 4_096)
        #expect(input.prompt.contains("Primary draft:\n" + original))
        #expect(input.maximumResponseTokens == VoiceCorrectionBudget.responseTokens(for: original.utf8.count))
        if withContext {
            #expect(input.prompt.contains("Session: ctrlx"))
            #expect(input.prompt.contains("newest"))
            #expect(!input.prompt.contains("oldest"))
        }
    }

    @Test("Mixed-language instructions and real vocabulary fit the legacy on-device budget", arguments: VoiceCorrectionBenchmark.samples.filter { $0.id.hasPrefix("mixed-") })
    func mixedLanguageBudget(_ sample: VoiceCorrectionBenchmarkSample) async throws {
        let context = VoiceInputContextSnapshot(
            paneMetadata: ["Session: ctrlx", "Window: feature-bug", "Current path: /tmp/macinput"],
            terminalText: sample.terminalContext
        )
        let input = try #require(try await VoiceCorrectionBudget.onDeviceInput(
            recognition: sample.recognition,
            terminalContext: context, contextualTerms: VoiceInputVocabulary.terms(for: context),
            localeIdentifier: "zh-Hans-CN", contextSize: 4_096, countTokens: { $0.utf8.count }
        ))
        #expect(input.instructions.utf8.count + input.prompt.utf8.count + input.maximumResponseTokens + 128 <= 4_096)
        #expect(input.prompt.contains("Primary draft:\n" + sample.recognition.primaryTranscript))
        #expect(input.prompt.contains("Session: ctrlx"))
        #expect(input.instructions.contains("Chinese phonetic text"))
    }

    @Test("Fits the entire request and output, preserving recent context and metadata")
    func boundedContext() async throws {
        let original = "检查新窗口的问题，不要发布。"
        let context = VoiceInputContextSnapshot(
            paneMetadata: ["Session: reel", "Current path: /tmp/reel"],
            terminalText: "oldest" + String(repeating: "中文终端输出", count: 3_000) + "newest"
        )
        let input = try #require(try await VoiceCorrectionBudget.onDeviceInput(
            recognition: VoiceRecognitionResult(primaryTranscript: original),
            terminalContext: context, contextualTerms: [], localeIdentifier: "zh-Hans-CN",
            contextSize: 4_096, countTokens: { $0.utf8.count }
        ))
        #expect(input.instructions.utf8.count + input.prompt.utf8.count + input.maximumResponseTokens + 128 <= 4_096)
        #expect(input.prompt.contains(original))
        #expect(input.prompt.contains("Session: reel"))
        #expect(input.prompt.contains("newest"))
        #expect(!input.prompt.contains("oldest"))
    }

    @Test("Optional hints can be dropped but the primary draft is never cut")
    func oversizedHints() async throws {
        let original = "只检查，不要修改。"
        let input = try #require(try await VoiceCorrectionBudget.onDeviceInput(
            recognition: VoiceRecognitionResult(
                primaryTranscript: original,
                alternativeTranscripts: [String(repeating: "候选", count: 3_000)],
                liveTranscript: String(repeating: "实时", count: 3_000)
            ),
            terminalContext: .init(terminalText: "recent text"), contextualTerms: [], localeIdentifier: "zh-Hans-CN",
            contextSize: 4_096, countTokens: { $0.utf8.count }
        ))
        #expect(input.prompt.contains(original))
        #expect(!input.prompt.contains("Phonetic alternatives"))
        #expect(!input.prompt.contains("Live phonetic hint"))
    }

    @Test("An utterance that cannot fit is left uncorrected")
    func oversizedOriginal() async throws {
        #expect(try await VoiceCorrectionBudget.onDeviceInput(
            recognition: VoiceRecognitionResult(primaryTranscript: String(repeating: "长句", count: 2_000)),
            terminalContext: nil, contextualTerms: [], localeIdentifier: "zh-Hans-CN",
            contextSize: 4_096, countTokens: { $0.utf8.count }
        ) == nil)
    }

    @Test("The budget uses the supplied tokenizer instead of treating characters as tokens")
    func tokenizedBudget() async throws {
        let input = try #require(try await VoiceCorrectionBudget.onDeviceInput(
            recognition: VoiceRecognitionResult(primaryTranscript: String(repeating: "原文", count: 300)),
            terminalContext: .init(terminalText: String(repeating: "背景", count: 3_000)), contextualTerms: [], localeIdentifier: "zh-Hans-CN",
            contextSize: 4_096, countTokens: { ($0.utf8.count + 2) / 3 }
        ))
        #expect(input.maximumResponseTokens == 1_264)
        #expect((input.instructions.utf8.count + 2) / 3 + (input.prompt.utf8.count + 2) / 3 + input.maximumResponseTokens + 128 <= 4_096)
    }

    @Test("Cancellation while counting tokens cannot publish a prepared correction")
    func cancellation() async throws {
        let task = Task {
            try await VoiceCorrectionBudget.onDeviceInput(
                recognition: VoiceRecognitionResult(primaryTranscript: "检查"),
                terminalContext: nil, contextualTerms: [], localeIdentifier: "zh-Hans-CN",
                contextSize: 4_096
            ) { text in
                try await Task.sleep(for: .seconds(10))
                return text.utf8.count
            }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("Voice correction literal preservation")
struct VoiceCorrectionLiteralTests {
    @Test("Rejects changed or omitted literal evidence", arguments: [
        ("端口改为8080", "端口改为8081"),
        ("保持版本v3.0.57", "保持版本v3.0.58"),
        ("温度是-10", "温度是10"),
        ("主机为192.168.1.1", "主机为192.168.1.2"),
        ("保留 --verbose 参数", "保留 --force 参数"),
        ("打开 /tmp/report.txt", "打开 /tmp/other.txt"),
        ("打开 ./output/report.txt", "打开 ./other/report.txt"),
        ("只检查 `git status`", "只检查 `git reset`"),
        ("使用 port=8080", "使用 port=8081"),
        ("等5分钟再重试", "等一下再重试"),
    ])
    func changedLiterals(_ original: String, _ candidate: String) {
        #expect(VoiceTranscriptCorrectionPolicy.accepted(candidate, replacing: original) == original)
    }

    @Test("Still corrects homophones and mixed-language names, including existing benchmark errors")
    func semanticCorrection() {
        #expect(VoiceTranscriptCorrectionPolicy.accepted("检查8080端口", replacing: "检察8080端口") == "检查8080端口")
        #expect(VoiceTranscriptCorrectionPolicy.accepted("安装到iPhone Air", replacing: "安装到iPhoner") == "安装到iPhone Air")
        for sample in VoiceCorrectionBenchmark.samples.prefix(3) {
            #expect(VoiceTranscriptCorrectionPolicy.accepted(sample.referenceTranscript, replacing: sample.recognition.primaryTranscript) == sample.referenceTranscript)
        }
    }
}

@Suite("Voice input contextual vocabulary")
struct VoiceInputContextualVocabularyTests {
    @Test("Shared vocabulary includes common Git terms without duplication or exceeding the speech hint limit")
    func gitTerms() {
        let terms = VoiceInputVocabulary.terms
        for term in ["branch", "commit", "develop", "diff", "main", "master", "merge", "rebase", "worktree"] {
            #expect(terms.contains(term))
        }
        #expect(Set(terms.map { $0.lowercased() }).count == terms.count)
        #expect(terms.count + 8 <= 100)
    }

    @Test("Adds bounded metadata terms but never consumes terminal output")
    func projectTerms() {
        let context = VoiceInputContextSnapshot(
            paneMetadata: VoiceInputContext.paneMetadata(
                sessionName: "Reel", windowName: "opening-scene", command: "codex", currentPath: "/tmp/storybook"
            ),
            terminalText: "Session: InjectedTerm\nCurrent path: /tmp/OutputOnly"
        )
        let terms = VoiceInputVocabulary.terms(for: context)
        #expect(terms.contains("Reel"))
        #expect(terms.contains("opening-scene"))
        #expect(terms.contains("opening"))
        #expect(terms.contains("storybook"))
        #expect(!terms.contains("InjectedTerm"))
        #expect(!terms.contains("OutputOnly"))
        #expect(terms.count <= VoiceInputVocabulary.terms.count + 8)
    }

    @Test("Vocabulary is deduplicated and recalculated for each recording")
    func freshVocabulary() {
        #expect(VoiceInputVocabulary.terms(for: .init(paneMetadata: ["Session: ctrlx", "Window: CTRLX"])).count == VoiceInputVocabulary.terms.count)
        let first = VoiceInputVocabulary.terms(for: .init(paneMetadata: ["Session: ProjectAlpha"]))
        let next = VoiceInputVocabulary.terms(for: .init(paneMetadata: ["Session: ProjectBeta"]))
        #expect(first.contains("ProjectAlpha"))
        #expect(!next.contains("ProjectAlpha"))
        #expect(next.contains("ProjectBeta"))
        #expect(VoiceInputVocabulary.terms(for: nil) == VoiceInputVocabulary.terms)
    }

    @Test("Rejects long titles and control-like text")
    func invalidMetadata() {
        #expect(VoiceInputVocabulary.terms(for: .init(paneMetadata: ["Session: " + String(repeating: "A", count: 200)])) == VoiceInputVocabulary.terms)
        #expect(VoiceInputVocabulary.terms(for: .init(paneMetadata: ["Session: \u{1b}[31mBadTitle"])) == VoiceInputVocabulary.terms)
    }
}
