import Testing
@testable import CtrlxCommon

@Suite("Voice input vocabulary")
struct VoiceInputVocabularyTests {
    @Test("Contains common mixed-language product terms")
    func productTerms() {
        #expect(VoiceInputVocabulary.terms.contains("iPhone Air"))
        #expect(VoiceInputVocabulary.terms.contains("Claude Code"))
        #expect(VoiceInputVocabulary.terms.contains("CtrlX"))
    }

    @Test("Does not contain duplicate terms")
    func uniqueTerms() {
        #expect(Set(VoiceInputVocabulary.terms).count == VoiceInputVocabulary.terms.count)
    }
}

@Suite("Voice input text composer")
struct VoiceInputTextComposerTests {
    @Test("Uses the transcript for an empty draft")
    func emptyDraft() {
        #expect(VoiceInputTextComposer.appending("检查构建", to: "") == "检查构建")
    }

    @Test("Separates an existing draft from dictated text")
    func existingDraft() {
        #expect(
            VoiceInputTextComposer.appending("并安装到真机", to: "完成构建")
                == "完成构建 并安装到真机"
        )
    }

    @Test("Preserves existing trailing whitespace")
    func trailingWhitespace() {
        #expect(VoiceInputTextComposer.appending("--verbose", to: "xcodebuild ") == "xcodebuild --verbose")
    }

    @Test("Ignores an empty partial result")
    func emptyTranscript() {
        #expect(VoiceInputTextComposer.appending("  \n", to: "existing draft") == "existing draft")
    }
}

@Suite("Voice input transcript state")
struct VoiceInputTranscriptStateTests {
    @Test("Volatile results replace only the active phrase")
    func volatileResults() {
        var state = VoiceInputTranscriptState()

        #expect(state.receive("正在", isFinal: false) == "正在")
        #expect(state.receive("正在识别", isFinal: false) == "正在识别")
    }

    @Test("Final results are never replaced by later volatile results")
    func finalizedResults() {
        var state = VoiceInputTranscriptState()
        _ = state.receive("第一段", isFinal: false)
        _ = state.receive("第一段。", isFinal: true)

        #expect(state.receive("第二", isFinal: false) == "第一段。第二")
        #expect(state.receive("第二段。", isFinal: true) == "第一段。第二段。")
    }

    @Test("Reset clears finalized and volatile text")
    func reset() {
        var state = VoiceInputTranscriptState()
        _ = state.receive("已确认", isFinal: true)
        _ = state.receive("未确认", isFinal: false)

        state.reset()

        #expect(state.text.isEmpty)
    }
}

@Suite("Stable live voice transcript")
struct VoiceInputStableTranscriptStateTests {
    @Test("Publishes the first result immediately and appends extensions")
    func immediateAppend() {
        var state = VoiceInputStableTranscriptState()

        #expect(state.receive("我在") == "我在")
        #expect(state.receive("我在往常") == "我在往常")
        #expect(state.receive("我在往常输入") == "我在往常输入")
    }

    @Test("Never rewrites an already published prefix")
    func noLiveRewrite() {
        var state = VoiceInputStableTranscriptState()
        _ = state.receive("这是语音")
        _ = state.receive("这是语音输入")

        #expect(state.receive("那是语音输入") == "这是语音输入")
    }

    @Test("Reset starts a fresh recognition")
    func reset() {
        var state = VoiceInputStableTranscriptState()
        _ = state.receive("first")
        _ = state.receive("first phrase")

        state.reset()

        #expect(state.receive("next") == "next")
        #expect(state.receive("next phrase") == "next phrase")
    }
}

@Suite("Voice recognition candidates")
struct VoiceRecognitionCandidateAccumulatorTests {
    @Test("Combines segmented alternatives while keeping the primary first")
    func combinesSegments() {
        var accumulator = VoiceRecognitionCandidateAccumulator(maximumCandidateCount: 5)
        accumulator.append(primary: "安装到", alternatives: ["安转到"])
        accumulator.append(primary: "iPhone Air", alternatives: ["iPhoner"])

        let result = accumulator.makeResult(
            liveTranscript: "安装到iPhoner",
            diagnosticID: "test"
        )

        #expect(result.primaryTranscript == "安装到iPhone Air")
        #expect(result.alternativeTranscripts.contains("安转到iPhone Air"))
        #expect(result.alternativeTranscripts.contains("安装到iPhoner"))
        #expect(result.liveTranscript == "安装到iPhoner")
    }

    @Test("Drops duplicate and empty alternatives")
    func uniqueAlternatives() {
        var accumulator = VoiceRecognitionCandidateAccumulator()
        accumulator.append(
            primary: "CtrlX",
            alternatives: ["CtrlX", "", "control X", "control X"]
        )

        let result = accumulator.makeResult(liveTranscript: "", diagnosticID: "test")

        #expect(result.primaryTranscript == "CtrlX")
        #expect(result.alternativeTranscripts == ["control X"])
    }

    @Test("Uses the live transcript when accurate recognition is empty")
    func liveFallback() {
        let result = VoiceRecognitionCandidateAccumulator().makeResult(
            liveTranscript: "继续安装",
            diagnosticID: "test"
        )

        #expect(result.bestAvailableTranscript == "继续安装")
    }
}

@Suite("Voice input context")
struct VoiceInputContextTests {
    @Test("Keeps only the most recent terminal context")
    func terminalSuffix() {
        #expect(
            VoiceInputContext.terminalExcerpt("0123456789", maximumCount: 4)
                == "…789"
        )
    }

    @Test("Ignores blank terminal context")
    func blankContext() {
        #expect(VoiceInputContext.terminalExcerpt(" \n ") == nil)
    }

    @Test("Builds one bounded context while preserving pane metadata")
    func assembledContext() throws {
        let context = try #require(
            VoiceInputContext.makeTerminalContext(
                terminalText: "oldest\n" + String(repeating: "x", count: 80) + "\nnewest",
                metadata: [
                    "Session: coding",
                    "Window: editor",
                    "Current path: /tmp/ctrlx",
                ],
                maximumCount: 100
            )
        )

        #expect(context.count == 100)
        #expect(context.hasPrefix("Session: coding\nWindow: editor\nCurrent path: /tmp/ctrlx"))
        #expect(context.contains("Recent terminal text:\n…"))
        #expect(context.hasSuffix("newest"))
        #expect(!context.contains("oldest"))
    }
}

@Suite("Voice transcript correction prompt")
struct VoiceTranscriptCorrectionPromptTests {
    @Test("Uses a configured provider before the on-device fallback")
    func providerFirstRouting() {
        #expect(
            VoiceTranscriptCorrectionRouting.routes(hasProviderSelection: true)
                == [.provider, .onDevice]
        )
        #expect(
            VoiceTranscriptCorrectionRouting.routes(hasProviderSelection: false)
                == [.onDevice]
        )
    }

    @Test("Allows whole-sentence semantics to fix a homophone outside the candidates")
    func semanticHomophoneGuidance() {
        let instructions = VoiceTranscriptCorrectionPrompt.instructions(
            localeIdentifier: "zh-Hans-CN",
            contextualTerms: ["CtrlX"]
        )

        #expect(instructions.contains("all fallible phonetic evidence"))
        #expect(instructions.contains("absent from every candidate"))
        #expect(instructions.contains("语音书为"))
        #expect(instructions.contains("语音输入"))
        #expect(instructions.contains("正在开。的这个项目"))
        #expect(instructions.contains("正在开发的这个项目"))
        #expect(instructions.contains("这些相信的词"))
        #expect(instructions.contains("这些相近的词"))
        #expect(instructions.contains("do not merely copy the primary draft"))
        #expect(!instructions.contains("Fix only clear recognition errors"))
    }

    @Test("Corrects English speech while protecting only explicit code")
    func englishCorrectionGuidance() {
        let instructions = VoiceTranscriptCorrectionPrompt.instructions(
            localeIdentifier: "zh-Hans-CN",
            contextualTerms: ["CtrlX", "Claude Code", "iPhone Air"]
        )

        #expect(instructions.contains("English-looking span as an approximate sound"))
        #expect(instructions.contains("Known terms are canonical spellings"))
        #expect(instructions.contains("CtrlX, Claude Code, iPhone Air"))
        #expect(instructions.contains("correct \"Wise button\" to \"Voice button\""))
        #expect(instructions.contains("explicitly code-shaped"))
        #expect(instructions.contains("`--verbose`"))
        #expect(instructions.contains("negation, restriction and condition"))
        #expect(instructions.contains("不要发布"))
    }

    @Test("Keeps recent pane context bounded for semantic correction")
    func recentPaneContext() {
        let terminalText = String(repeating: "x", count: 13_000) + "latest output"
        let context = VoiceInputContext.makeTerminalContext(
            terminalText: terminalText,
            metadata: ["Current path: /tmp/ctrlx"]
        )
        let prompt = VoiceTranscriptCorrectionPrompt.make(
            recognition: VoiceRecognitionResult(primaryTranscript: "修复这个问题"),
            terminalContext: context
        )

        #expect(context?.count == VoiceInputContext.maximumTerminalCharacterCount)
        #expect(context?.hasPrefix("Current path: /tmp/ctrlx") == true)
        #expect(context?.hasSuffix("latest output") == true)
        #expect(prompt.contains("Recent pane context"))
        #expect(!prompt.contains(String(repeating: "x", count: 13_000)))

        let instructions = VoiceTranscriptCorrectionPrompt.instructions(
            localeIdentifier: "zh-Hans-CN",
            contextualTerms: []
        )
        #expect(instructions.contains("topic and spelling evidence"))
        #expect(!instructions.contains("Ignore it when judging the semantics"))
    }

    @Test("Presents alternatives and live text as phonetic hints")
    func phoneticHints() {
        let prompt = VoiceTranscriptCorrectionPrompt.make(
            recognition: VoiceRecognitionResult(
                primaryTranscript: "安装到iPhoner",
                alternativeTranscripts: ["安装到iPhone Air"],
                liveTranscript: "安装到爱疯Air"
            ),
            terminalContext: nil
        )

        #expect(prompt.contains("Primary draft:\n安装到iPhoner"))
        #expect(prompt.contains("Phonetic alternatives:\n1. 安装到iPhone Air"))
        #expect(prompt.contains("Live phonetic hint:\n安装到爱疯Air"))
    }
}

@Suite("Voice transcript correction policy")
struct VoiceTranscriptCorrectionPolicyTests {
    @Test("Accepts a concise corrected transcript")
    func correctedTranscript() {
        #expect(
            VoiceTranscriptCorrectionPolicy.accepted(
                "但是在网上就输入不了了哦",
                replacing: "但是在往常就输不了了哦"
            ) == "但是在网上就输入不了了哦"
        )
    }

    @Test("Keeps the original when correction is empty")
    func emptyCorrection() {
        #expect(
            VoiceTranscriptCorrectionPolicy.accepted("  ", replacing: "xcodebuild")
                == "xcodebuild"
        )
    }

    @Test("Keeps the original when the model adds multiple lines")
    func multilineCorrection() {
        #expect(
            VoiceTranscriptCorrectionPolicy.accepted(
                "Corrected:\nxcodebuild",
                replacing: "xcodebuild"
            ) == "xcodebuild"
        )
    }

    @Test("Keeps the original when the model expands it unexpectedly")
    func expandedCorrection() {
        let explanation = String(repeating: "explanation ", count: 10)

        #expect(
            VoiceTranscriptCorrectionPolicy.accepted(explanation, replacing: "test")
                == "test"
        )
    }
}
