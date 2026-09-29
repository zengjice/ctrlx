import Clocks
import ConcurrencyExtras
import CtrlxCommon
import Dependencies
import Testing
@testable import CtrlxFeature

@Suite("iOS Codex question auto-expansion")
@MainActor
struct TerminalCodexQuestionExpansionTests {
    private static func prompt(_ count: Int, compact: Bool = false, suffix: String = "") -> CodexQuestionPrompt? {
        let lines = count == 0 ? ["› Ask Codex to do anything"] : [
            "Queued follow-up inputs", "? \(count) \(count == 1 ? "question" : "questions")\(suffix)",
            compact ? "shift+← to answer" : "shift + ← to answer", "› Ask Codex to do anything",
        ]
        return CodexQuestionPrompt(lines: lines, cursorRow: lines.count - 1, cursorColumn: 2)
    }

    @Test("Question age ticks neither postpone expansion nor reopen a dismissed queue")
    func timerTicks() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            try await withDependencies { $0.continuousClock = clock } operation: {
                var current = try #require(Self.prompt(1, compact: true, suffix: " · 14s"))
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { sent.append($0); return true })
                defer { opener.invalidate() }
                opener.schedule()
                for age in [15, 16, 17] {
                    await clock.advance(by: .milliseconds(100))
                    current = try #require(Self.prompt(1, compact: true, suffix: " · \(age)s"))
                    opener.schedule()
                }
                #expect(sent.isEmpty)
                await clock.advance(by: .milliseconds(50))
                await Task.megaYield()
                #expect(sent == [1])
                // A later minute-format tick must not send another intent.
                current = try #require(Self.prompt(1, compact: true, suffix: " · 1m 02s"))
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent == [1])
            }
        }
    }

    @Test("Both footer formats wait for 350 ms, not every output chunk", arguments: [false, true])
    func stableFooter(compact: Bool) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    readPrompt: { Self.prompt(2, compact: compact) },
                    enqueue: { sent.append($0); return true }
                )
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .milliseconds(349))
                #expect(sent.isEmpty)
                // Unrelated streaming output must not starve a stable footer.
                opener.schedule()
                await clock.advance(by: .milliseconds(1))
                await Task.megaYield()
                #expect(sent == [2])
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent == [2])
            }
        }
    }

    @Test("A changed or partially painted footer starts a new stability window")
    func repaint() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var current = Self.prompt(1)
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { sent.append($0); return true })
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .milliseconds(200))
                current = nil
                opener.schedule()
                current = Self.prompt(2)
                opener.schedule()
                await clock.advance(by: .milliseconds(150))
                #expect(sent.isEmpty)
                await clock.advance(by: .milliseconds(200))
                await Task.megaYield()
                #expect(sent == [2])
            }
        }
    }

    @Test("Rechecks live eligibility before sending, even without an output event")
    func lostEligibility() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                // UIKit returns nil for inactive panes, drafts, IME, selection,
                // scrollback, drag/deceleration, background or detached views.
                var eligible = true
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    readPrompt: { eligible ? Self.prompt(1) : nil },
                    enqueue: { sent.append($0); return true }
                )
                defer { opener.invalidate() }
                opener.schedule()
                eligible = false
                await clock.advance(by: .seconds(1))
                #expect(sent.isEmpty)
                eligible = true
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(sent == [1])
            }
        }
    }

    @Test("User input cancels the pending check; later output can schedule anew")
    func inputCancels() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { sent.append($0); return true })
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .milliseconds(200))
                opener.cancelPending()
                await clock.advance(by: .seconds(1))
                #expect(sent.isEmpty)
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(sent == [1])
            }
        }
    }

    @Test("Escape/remount dedup is Host-owned; reductions and zero also reach it")
    func countTransitions() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var current: CodexQuestionPrompt?
                var sent: [Int] = []
                var opened: [Int] = []
                var host = CodexQuestionExpansionState()
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: {
                    sent.append($0)
                    if host.observe($0) { opened.append($0) }
                    return true
                })
                defer { opener.invalidate() }
                for count in [4, 4, 3, 4, 0, 1] {
                    current = nil // Expanded form or intervening output.
                    opener.schedule()
                    current = Self.prompt(count, compact: true)
                    opener.schedule()
                    await clock.advance(by: .milliseconds(350))
                    await Task.megaYield()
                }
                #expect(sent == [4, 3, 4, 0, 1])
                #expect(opened == [4, 4, 1])
                let remounted = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: {
                    if host.observe($0) { opened.append($0) }
                    return true
                })
                defer { remounted.invalidate() }
                remounted.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(opened == [4, 4, 1])
            }
        }
    }

    @Test("A stream reset or disconnect does not consume an unqueued attempt")
    func unavailableQueue() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var ready = false
                var attempts = 0
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { _ in
                    attempts += 1
                    return ready
                })
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .seconds(5))
                await Task.megaYield()
                #expect(attempts == 1) // No polling/retry loop.
                ready = true
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(attempts == 2)
            }
        }
    }

    @Test("Dismantling a pane permanently cancels its queued check")
    func dismantle() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { sent.append($0); return true })
                opener.schedule()
                opener.invalidate()
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent.isEmpty)
            }
        }
    }
}
