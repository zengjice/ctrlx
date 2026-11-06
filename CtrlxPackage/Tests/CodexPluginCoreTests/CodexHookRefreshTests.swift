import CtrlxNetworking
import CtrlxPluginProtocol
import Testing
@testable import CodexPluginCore

struct CodexHookRefreshTests {
    @Test("Refresh recognizes the dedicated hook plugin and the legacy source, never another marketplace", arguments: ["ctrlx-hooks@ctrlx", "ctrlx@ctrlx", "ctrlx-hooks@other", "other@other"])
    func refreshSources(_ source: String) {
        let lines = ["UserPromptSubmit hooks", "Turn hooks on or off. Your changes are saved automatically.", "› [x] 1 Hook", "Event UserPromptSubmit", "Source Plugin - \(source)", "Command /fixture/hook.py", "Mode Sync", "Trust Trusted", "space/enter toggle · esc back"]
        #expect(CodexPluginCore().hookTrustAllows(.toggle, lines: lines) == ["ctrlx-hooks@ctrlx", "ctrlx@ctrlx"].contains(source))
    }

    @Test("Refresh preserves disabled and foreign hooks and confirms persistence", arguments: [140, 60, 48])
    func refresh(width: Int) async throws {
        let replay = RefreshReplay(width: width)
        let result = try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: true)
        #expect(result == .alreadyTrusted)
        #expect(await replay.enabled == [true, false, true])
        #expect(await replay.persisted == [true, false, true])
        #expect(await replay.toggled == [2, 2])
        #expect(await replay.opens == 3)
        #expect(await replay.page == .composer)
    }

    @Test("Restoration is attempted after an ambiguous off or a failed on", arguments: [RefreshReplay.Failure.afterOff, .restoreOnce])
    fileprivate func restoresAfterFailure(failure: RefreshReplay.Failure) async throws {
        let replay = RefreshReplay(failure: failure)
        do {
            _ = try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: true)
            Issue.record("Injected failure must not be reported as success")
        } catch let error as AgentHookTrustError {
            #expect(!error.preservePanel)
        }
        #expect(await replay.persisted == [true, false, true])
        #expect(await replay.toggled == [2, 2])
    }

    @Test("Human takeover never receives recovery keystrokes")
    func takeover() async throws {
        let replay = RefreshReplay(failure: .takeover)
        do {
            _ = try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: true)
            Issue.record("Takeover must fail")
        } catch let error as AgentHookTrustError {
            #expect(error.preservePanel)
            #expect(error.message.contains("turn it back on"))
        }
        #expect(await replay.toggled == [2])
        #expect(await replay.actionsAfterTakeover == 0)
    }

    @Test("Optimistic enablement cannot report successful restoration")
    func failedPersistence() async throws {
        let replay = RefreshReplay(failure: .persistOn)
        do {
            _ = try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: true)
            Issue.record("Unpersisted enablement must fail")
        } catch let error as AgentHookTrustError {
            #expect(error.preservePanel)
        }
        #expect(await replay.persisted == [true, false, false])
    }

    @Test("An unsaved disable cannot report a successful refresh")
    func failedDisablePersistence() async throws {
        let replay = RefreshReplay(failure: .persistOff)
        do {
            _ = try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: true)
            Issue.record("Unpersisted disablement must fail")
        } catch let error as AgentHookTrustError {
            #expect(!error.preservePanel)
            #expect(error.message.contains("temporary hook setting"))
        }
        #expect(await replay.persisted == [true, false, true])
        #expect(await replay.toggled == [2])
    }

    @Test("Missing enabled CtrlX hooks cannot enable disabled or foreign hooks", arguments: [false, true])
    func noEligibleHook(foreign: Bool) async throws {
        let replay = RefreshReplay(noEligible: true, foreign: foreign)
        await #expect(throws: AgentHookTrustError.self) {
            _ = try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: true)
        }
        #expect(await replay.toggled.isEmpty)
        #expect(await replay.persisted == (foreign ? [true, false, true] : [true, false, false]))
    }

    @Test("Legacy approval-only clients never toggle an already trusted hook")
    func legacy() async throws {
        let replay = RefreshReplay()
        #expect(try await CodexPluginCore().trustHooks(terminal: await replay.terminal, refreshIfTrusted: false) == .alreadyTrusted)
        #expect(await replay.toggled.isEmpty)
    }
}

private actor RefreshReplay {
    enum Failure: Sendable { case none, afterOff, restoreOnce, takeover, persistOn, persistOff }
    enum Page { case composer, root, details }
    var page = Page.composer
    var enabled = [true, false, true]
    var persisted = [true, false, true]
    var toggled: [Int] = []
    var opens = 0
    var actionsAfterTakeover = 0
    private var takenOver = false
    private var didFail = false
    private var event = 0
    private var handler = 0
    private let width: Int
    private let failure: Failure
    private let foreign: Bool

    init(width: Int = 140, failure: Failure = .none, noEligible: Bool = false, foreign: Bool = false) {
        self.width = width
        self.failure = failure
        self.foreign = foreign
        if noEligible && !foreign {
            enabled[2] = false
            persisted[2] = false
        }
    }

    var terminal: AgentHookTrustTerminal {
        .init(read: { try await self.read() }, perform: { try await self.perform($0) })
    }

    func perform(_ action: AgentHookTrustAction) throws {
        if takenOver {
            actionsAfterTakeover += 1
            throw CancellationError()
        }
        switch action {
        case .open:
            opens += 1
            page = .root
            event = 0
            enabled = persisted
        case .close: page = .composer
        case .trustAll: Issue.record("Already trusted hooks must not be reapproved")
        case let .press(key, expected):
            #expect(try read() == expected)
            #expect(CodexPluginCore().hookTrustAllows(key, lines: expected))
            switch key {
            case .next:
                if page == .root {
                    event = min(2, event + 1)
                } else {
                    handler = min(2, handler + 1)
                }
            case .details: page = .details
                handler = 0
            case .back: page = .root
            case .toggle:
                if failure == .restoreOnce, !enabled[handler], !didFail {
                    didFail = true
                    throw AgentHookTrustError("Fixture: restore key was not sent")
                }
                enabled[handler].toggle()
                toggled.append(handler)
                if !(failure == .persistOn && enabled[handler]) && !(failure == .persistOff && !enabled[handler]) {
                    persisted[handler] = enabled[handler]
                }
                if failure == .afterOff, !didFail {
                    didFail = true
                    throw AgentHookTrustError("Fixture: off outcome was unknown")
                }
                if failure == .takeover {
                    takenOver = true
                }
            }
        }
    }

    func read() throws -> [String] {
        if takenOver {
            throw CancellationError()
        }
        if page == .composer {
            return ["› Ask Codex to do anything"]
        }
        if page == .root {
            let description = width == 48 ? ["Lifecycle hooks from config and enabled", "plugins."] : ["Lifecycle hooks from config and enabled plugins."]
            return ["Hooks"] + description + [width < 80 ? "Event Active/Installed" : "Event Installed Active Description"]
                + ["PreToolUse", "PostToolUse", "UserPromptSubmit"].enumerated().map { ($0.offset == event ? "› " : "  ") + $0.element + " 3 2 Description" }
                + ["enter details · esc close"]
        }
        let source = handler == 0 ? "foreign@foreign" : (foreign ? "ctrlx-hooks@other" : "ctrlx-hooks@ctrlx")
        let description = width < 80 ? ["Turn hooks on or off. Your changes are", "saved automatically."] : ["Turn hooks on or off. Your changes are saved automatically."]
        return ["UserPromptSubmit hooks"] + description
            + enabled.enumerated().map { ($0.offset == handler ? "› " : "  ") + "[\($0.element ? "x" : " ")] \($0.offset + 1) Hook" }
            + ["Event UserPromptSubmit", "Source Plugin - \(source)", "Command /fixture/hook-\(handler).sh", "Mode Sync", "Trust Trusted", "space/enter toggle · esc back"]
    }
}
