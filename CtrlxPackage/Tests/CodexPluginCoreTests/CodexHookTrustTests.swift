import CtrlxPluginProtocol
import Testing
@testable import CodexPluginCore

struct CodexHookTrustTests {
    private static func panel(_ review: Bool, width: Int = 140) -> [String] {
        let description = width == 48
            ? ["  Lifecycle hooks from config and enabled", "  plugins."]
            : ["  Lifecycle hooks from config and enabled plugins."]
        let heading = width < 80 ? "  Event Active/Installed"
            : (review ? "  Event Installed Active Review Description" : "  Event Installed Active Description")
        return ["  Hooks"] + description + [
            heading,
            "› UserPromptSubmit 1 0 Before a user prompt",
            review ? "  t trust all · enter review · esc close" : "  enter details · esc close", "",
        ]
    }

    @Test(arguments: [140, 60, 48])
    func recognizesOnlyTheRootControls(width: Int) {
        let core = CodexPluginCore()
        let pending = Self.panel(true, width: width)
        #expect(core.hookTrustPanel(lines: pending) == .needsReview)
        #expect(core.hookTrustPanel(lines: Self.panel(false, width: width)) == .trusted)
        #expect(core.hookTrustPanel(lines: ["UserPromptSubmit hooks", "t trust · esc back"]) == nil)
        #expect(core.hookTrustPanel(lines: ["Hooks", "t trust all · enter review · esc close"]) == nil)
        #expect(core.hookTrustPanel(lines: pending + ["› Ask Codex to do anything"]) == nil)
        #expect(core.hookTrustPanel(lines: Array(pending.dropFirst())) == nil)
        #expect(core.hookTrustPanel(lines: pending.filter { !$0.contains("Event") }) == nil)
        #expect(core.hookTrustPanel(lines: pending.filter { !$0.contains("plugins.") }) == nil)
        var issues = Self.panel(false, width: width)
        issues.insert("Issues", at: 2)
        #expect(core.hookTrustPanel(lines: issues) == nil)
    }

    private actor Replay {
        var actions: [AgentHookTrustAction] = []
        var opens = 0
        var approved = false
        let persists: Bool
        let unknown: Bool
        let width: Int
        init(persists: Bool = true, unknown: Bool = false, approved: Bool = false, width: Int = 140) {
            self.persists = persists
            self.unknown = unknown
            self.approved = approved
            self.width = width
        }

        func perform(_ action: AgentHookTrustAction) {
            actions.append(action)
            if action == .open {
                opens += 1
            }
            if action == .trustAll {
                approved = true
            }
        }

        func read() -> [String] {
            if unknown {
                return ["A different popup", "t trust"]
            }
            return CodexHookTrustTests.panel(!approved || (opens > 1 && !persists), width: width)
        }

        var terminal: AgentHookTrustTerminal {
            .init(read: { await self.read() }, perform: { await self.perform($0) })
        }
    }

    @Test("Success requires reopening the panel to verify persisted approval", arguments: [140, 60, 48])
    func approvesAndReadsBack(width: Int) async throws {
        let replay = Replay(width: width)
        try await CodexPluginCore().trustHooks(terminal: await replay.terminal)
        #expect(await replay.actions == [.open, .trustAll, .close, .open, .close])
    }

    @Test("Already trusted hooks do not receive a trust keystroke")
    func alreadyTrusted() async throws {
        let replay = Replay(approved: true)
        try await CodexPluginCore().trustHooks(terminal: await replay.terminal)
        #expect(await replay.actions == [.open, .close])
    }

    @Test("An optimistic repaint is not approval confirmation and is not retried")
    func failedPersistence() async {
        let replay = Replay(persists: false)
        await #expect(throws: AgentHookTrustError.self) { try await CodexPluginCore().trustHooks(terminal: await replay.terminal) }
        #expect(await replay.actions == [.open, .trustAll, .close, .open])
    }

    @Test("Unknown layouts never receive t")
    func unknownControls() async {
        let replay = Replay(unknown: true)
        await #expect(throws: AgentHookTrustError.self) { try await CodexPluginCore().trustHooks(terminal: await replay.terminal) }
        #expect(await replay.actions == [.open])
    }

    @Test
    func takeoverStopsTheSequence() async {
        let terminal = AgentHookTrustTerminal(read: { throw CancellationError() }, perform: { action in #expect(action == .open) })
        await #expect(throws: CancellationError.self) { try await CodexPluginCore().trustHooks(terminal: terminal) }
    }
}
