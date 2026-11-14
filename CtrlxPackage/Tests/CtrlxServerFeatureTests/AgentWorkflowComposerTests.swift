import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowComposerTests {
    private let codex = AgentWorkflowComposer(prompt: "› ", dimPlaceholder: "Ask Codex to do anything", pendingInputHints: ["Queued follow-up inputs"])
    private let claude = AgentWorkflowComposer(prompt: "❯ ", enclosedByRules: true, drawsInverseCursor: true)

    private func capture(_ rows: [String], cursor: Int, x: Int = 2, width: Int = 80, paste: Bool? = true, copyMode: Bool = false, visible: Bool = true) -> AgentWorkflowTerminalCapture {
        .init(
            ansi: rows.joined(separator: "\n") + "\n",
            width: width,
            height: rows.count,
            cursorX: x,
            cursorY: cursor,
            cursorVisible: visible,
            bracketedPaste: paste,
            inCopyMode: copyMode,
            foregroundCommand: "agent"
        )
    }

    @Test(arguments: ["codex", "claude"])
    func imageStagingRequiresTheExactVisibleAttachments(agent: String) {
        let composer = agent == "codex" ? codex : claude
        let prefix = composer.prompt
        let staged = capture([prefix + "[Image #1] [Image #2]", ""], cursor: 0, x: 24)
        #expect(AgentWorkflowComposerInspection.hasImages(staged, composer: composer, count: 2))
        #expect(!AgentWorkflowComposerInspection.hasImages(staged, composer: composer, count: 1))
        for text in ["[Image #1] not my draft", "[Image #2]", "[Image #1] [Image #2] changed", "/tmp/image.png"] {
            let other = capture([prefix + text, ""], cursor: 0, x: 24)
            #expect(!AgentWorkflowComposerInspection.hasImages(other, composer: composer, count: 2))
        }
        let wrapped = capture([prefix + "[Image #1] [Image #2]", "  [Image #3]", ""], cursor: 1, x: 12)
        #expect(AgentWorkflowComposerInspection.hasImages(wrapped, composer: composer, count: 3))
        let later = capture([prefix + "[Image #3] [Image #5]", ""], cursor: 0, x: 24)
        #expect(AgentWorkflowComposerInspection.imageNumbers(later, composer: composer) == [3, 5])
        let repeated = capture([prefix + "[Image #3] [Image #3]", ""], cursor: 0, x: 24)
        #expect(AgentWorkflowComposerInspection.imageNumbers(repeated, composer: composer) == nil)
        let copying = capture([prefix + "[Image #1] [Image #2]", ""], cursor: 0, copyMode: true)
        #expect(!AgentWorkflowComposerInspection.hasImages(copying, composer: composer, count: 2))
    }

    @Test
    func legacyModeKeepsComposerChecksAndDoesNotRetryReadyInput() async throws {
        let empty = capture(["› \u{1b}[2mAsk Codex to do anything\u{1b}[0m", ""], cursor: 0, paste: nil)
        var reads = 0
        let settled = try await AgentWorkflowComposerInspection.settledCapture(composer: codex) {
            reads += 1
            return empty
        }
        #expect(reads == 1)
        #expect(AgentWorkflowComposerInspection.inspect(settled, composer: codex).readiness == .ready)
        #expect(AgentWorkflowComposerInspection.inspect(settled, composer: codex).issue == nil)
        let draft = capture(["› unsent text", ""], cursor: 0, paste: nil)
        #expect(AgentWorkflowComposerInspection.readiness(draft, composer: codex) == .draft)
        let rule = String(repeating: "─", count: 80)
        let claudeEmpty = capture([rule, "❯ \u{1b}[7m \u{1b}[0m", rule], cursor: 1, paste: nil, visible: false)
        #expect(AgentWorkflowComposerInspection.readiness(claudeEmpty, composer: claude) == .ready)
        let images = capture(["› [Image #1] [Image #2]", ""], cursor: 0, x: 24, paste: nil)
        #expect(AgentWorkflowComposerInspection.hasImages(images, composer: codex, count: 2))
        let wrongImages = capture(["› [Image #1] other draft", ""], cursor: 0, x: 24, paste: nil)
        #expect(!AgentWorkflowComposerInspection.hasImages(wrongImages, composer: codex, count: 1))
    }

    @Test
    func unavailableInputExplainsTheFailedCheck() {
        let rows = ["› \u{1b}[2mAsk Codex to do anything\u{1b}[0m", ""]
        let cases: [(AgentWorkflowTerminalCapture, String)] = [
            (capture(rows, cursor: 0, copyMode: true), "copy mode"),
            (capture(rows, cursor: 0, paste: false), "paste mode"),
            (capture(rows, cursor: 0, x: 5, paste: nil), "start of the Agent input"),
            (capture(rows, cursor: 0, paste: nil, visible: false), "cursor is not visible"),
            (capture(["$ ", ""], cursor: 0, paste: nil), "prompt was not recognized"),
        ]
        for (terminal, reason) in cases {
            let inspection = AgentWorkflowComposerInspection.inspect(terminal, composer: codex)
            #expect(inspection.readiness == .unavailable)
            #expect(inspection.issue?.contains(reason) == true)
        }
    }

    @Test
    func nativeCodexPlaceholderIsEmptyButIdenticalDraftIsNot() {
        // Empty composer captured from Codex 0.163.0. Text alone is ambiguous
        // after the user types the placeholder and moves the cursor to Home.
        let prefix = ["", "  >_ \u{1b}[1mOpenAI Codex\u{1b}[0;2m (v0.163.0)\u{1b}[0m", "", "", ""]
        let empty = capture(prefix + ["\u{1b}[1m›\u{1b}[0m \u{1b}[2mAsk Codex to do anything\u{1b}[0m", ""], cursor: 5)
        #expect(AgentWorkflowComposerInspection.readiness(empty, composer: codex) == .ready)
        let draft = capture(prefix + ["› Ask Codex to do anything", ""], cursor: 5)
        #expect(AgentWorkflowComposerInspection.readiness(draft, composer: codex) == .draft)
    }

    @Test
    func nativeClaudeEmptyComposerAndHomePositionDraft() {
        // Claude Code 2.1.308 uses NBSP after ❯ and a full-width rule either side.
        let rule = String(repeating: "─", count: 80)
        for text in ["", "workflow draft", "你好 🐈"] {
            let terminal = capture([rule, "❯\u{a0}\(text)", rule, "  ⏵⏵ auto mode on (shift+tab to cycle)"], cursor: 1)
            #expect(AgentWorkflowComposerInspection.readiness(terminal, composer: claude) == (text.isEmpty ? .ready : .draft))
        }
    }

    @Test
    func blankFirstLineDoesNotHideMultilineDraft() {
        let rule = String(repeating: "─", count: 80)
        let terminal = capture([rule, "❯ ", "  important unsent text", rule], cursor: 1)
        #expect(AgentWorkflowComposerInspection.readiness(terminal, composer: claude) == .draft)
    }

    @Test
    func nativeClaudeInverseCaretAcceptsOnlyEmptyInput() {
        // Native 2.1.308 capture: cursor_flag=0 and an inverse blank at x=2.
        let rule = "\u{1b}[38;5;244m" + String(repeating: "─", count: 140)
        let caret = "\u{1b}[39m❯\u{a0}\u{1b}[7m \u{1b}[0m"
        let empty = capture([rule, caret, rule, "manual mode on"], cursor: 1, width: 140, visible: false)
        #expect(AgentWorkflowComposerInspection.readiness(empty, composer: claude) == .ready)
        let draft = capture([rule, caret + "draft", rule], cursor: 1, width: 140, visible: false)
        #expect(AgentWorkflowComposerInspection.readiness(draft, composer: claude) == .draft)
        let multiline = capture([rule, caret, "  unsent second line", rule], cursor: 1, width: 140, visible: false)
        #expect(AgentWorkflowComposerInspection.readiness(multiline, composer: claude) == .draft)
        let ordinary = AgentWorkflowComposer(prompt: "❯ ", enclosedByRules: true)
        #expect(AgentWorkflowComposerInspection.readiness(empty, composer: ordinary) == .unavailable)
    }

    @Test
    func pendingQuestionsBlockAnOtherwiseEmptyComposer() {
        let terminal = capture(["Queued follow-up inputs", "? 1 question", "", "› \u{1b}[2mAsk Codex to do anything"], cursor: 3)
        #expect(AgentWorkflowComposerInspection.readiness(terminal, composer: codex) == .awaitingHuman)
    }

    @Test
    func unusableInputModesAndUnknownLayoutsAreRejected() {
        let rule = String(repeating: "─", count: 80)
        let lines = [rule, "❯ ", rule]
        for terminal in [capture(lines, cursor: 1, paste: false), capture(lines, cursor: 1, copyMode: true), capture(lines, cursor: 1, visible: false), capture(lines, cursor: 1, x: 4), capture(["shell> ", "", ""], cursor: 0)] {
            #expect(AgentWorkflowComposerInspection.readiness(terminal, composer: claude) == .unavailable)
        }
    }

    @Test
    func tabFitRedrawSettlesBeforeInspectingEmptyInput() async throws {
        // Native Codex 0.166.0: after Fit the cursor temporarily points at
        // an empty row, then returns to the unchanged dim placeholder.
        let redrawing = capture(["OpenAI Codex", "", "", "", ""], cursor: 2)
        let empty = capture(["OpenAI Codex", "", "› \u{1b}[2mAsk Codex to do anything\u{1b}[0m", "", ""], cursor: 2)
        #expect(AgentWorkflowComposerInspection.readiness(redrawing, composer: codex) == .unavailable)
        var reads = 0
        let result = try await AgentWorkflowComposerInspection.settledCapture(composer: codex) {
            reads += 1
            return reads == 1 ? redrawing : empty
        }
        #expect(reads == 2)
        #expect(AgentWorkflowComposerInspection.readiness(result, composer: codex) == .ready)
    }

    @Test(arguments: ["ready", "draft", "question", "copy-mode"])
    func knownInputStatesAreNotRetried(scenario: String) async throws {
        let snapshot: AgentWorkflowTerminalCapture
        switch scenario {
        case "draft": snapshot = capture(["› unsent task", ""], cursor: 0)
        case "question": snapshot = capture(["Queued follow-up inputs", "", "› \u{1b}[2mAsk Codex to do anything"], cursor: 2)
        default: snapshot = capture(["› \u{1b}[2mAsk Codex to do anything", ""], cursor: 0, copyMode: scenario == "copy-mode")
        }
        var reads = 0
        let result = try await AgentWorkflowComposerInspection.settledCapture(composer: codex) {
            reads += 1
            return snapshot
        }
        #expect(reads == 1)
        #expect(result.ansi == snapshot.ansi)
        #expect(AgentWorkflowComposerInspection.readiness(result, composer: codex) == AgentWorkflowComposerInspection.readiness(snapshot, composer: codex))
    }

    @Test
    func unknownInputDoesNotWaitIndefinitelyOrBecomeReady() async throws {
        let snapshot = capture(["", "", ""], cursor: 1)
        var reads = 0
        let result = try await AgentWorkflowComposerInspection.settledCapture(composer: codex) {
            reads += 1
            return snapshot
        }
        #expect(reads == 5)
        #expect(AgentWorkflowComposerInspection.readiness(result, composer: codex) == .unavailable)
    }

    @Test
    func cancelledRedrawWaitDoesNotReadAgain() async throws {
        let snapshot = capture(["", "", ""], cursor: 1)
        var reads = 0
        let task = Task {
            try await AgentWorkflowComposerInspection.settledCapture(composer: codex) {
                reads += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return snapshot
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(reads == 1)
    }

    @Test
    func identityFailureDuringRedrawIsNotSuppressed() async throws {
        let snapshot = capture(["", "", ""], cursor: 1)
        var reads = 0
        let error = AgentWorkflowError("The pane was replaced.")
        await #expect(throws: error) {
            try await AgentWorkflowComposerInspection.settledCapture(composer: codex) {
                reads += 1
                if reads > 1 {
                    throw error
                }
                return snapshot
            }
        }
        #expect(reads == 2)
    }
}
