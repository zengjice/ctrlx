import CtrlxNetworking
import CtrlxPluginProtocol
import Foundation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentWorkflowComposerTests {
    private let codex = AgentWorkflowComposer(prompt: "› ", dimPlaceholder: "Ask Codex to do anything", pendingInputHints: ["Queued follow-up inputs"])
    private let claude = AgentWorkflowComposer(prompt: "❯ ", enclosedByRules: true, drawsInverseCursor: true)

    private func capture(_ rows: [String], cursor: Int, x: Int = 2, width: Int = 80, paste: Bool = true, copyMode: Bool = false, visible: Bool = true) -> AgentWorkflowTerminalCapture {
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
}
