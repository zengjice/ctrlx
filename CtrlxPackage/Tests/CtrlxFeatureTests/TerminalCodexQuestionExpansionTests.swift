import Clocks
import ConcurrencyExtras
import CtrlxCommon
import Dependencies
import Testing
@testable import CtrlxFeature

@Suite("iOS Codex question auto-expansion")
@MainActor
struct TerminalCodexQuestionExpansionTests {
    private nonisolated static let supportedHints = [
        "shift + ← to answer", "shift+← to answer", "shift← to answer",
        "⇧← to answer", "⇧ + ← to answer", "Shift + Left to answer",
    ]

    private nonisolated static func prompt(_ count: Int, hint: String = "shift + ← to answer", suffix: String = "") -> CodexQuestionPrompt? {
        let lines = count == 0 ? ["› Ask Codex to do anything"] : [
            "Queued follow-up inputs", "? \(count) \(count == 1 ? "question" : "questions")\(suffix)",
            hint, "› Ask Codex to do anything",
        ]
        return CodexQuestionPrompt(lines: lines, cursorRow: lines.count - 1, cursorColumn: 2)
    }

    @Test("Question age ticks neither postpone expansion nor reopen a dismissed queue", arguments: supportedHints)
    func timerTicks(hint: String) async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            try await withDependencies { $0.continuousClock = clock } operation: {
                var current = try #require(Self.prompt(1, hint: hint, suffix: " · 14s"))
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { count, complete in sent.append(count)
                    complete(true)
                    return true
                })
                defer { opener.invalidate() }
                opener.schedule()
                for age in [15, 16, 17] {
                    await clock.advance(by: .milliseconds(100))
                    current = try #require(Self.prompt(1, hint: hint, suffix: " · \(age)s"))
                    opener.schedule()
                }
                #expect(sent.isEmpty)
                await clock.advance(by: .milliseconds(50))
                await Task.megaYield()
                #expect(sent == [1])
                // A later minute-format tick must not send another intent.
                current = try #require(Self.prompt(1, hint: hint, suffix: " · 1m 02s"))
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent == [1])
            }
        }
    }

    @Test("All footer formats wait for 350 ms, not every output chunk", arguments: supportedHints)
    func stableFooter(hint: String) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    readPrompt: { Self.prompt(2, hint: hint) },
                    enqueue: { count, complete in sent.append(count)
                        complete(true)
                        return true
                    }
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

    @Test("Changing between text and symbol hints does not restart stability or reopen Questions")
    func hintFormatting() async throws {
        try await withMainSerialExecutor {
            let clock = TestClock()
            try await withDependencies { $0.continuousClock = clock } operation: {
                var current = try #require(Self.prompt(1))
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { count, complete in sent.append(count)
                    complete(true)
                    return true
                })
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .milliseconds(200))
                current = try #require(Self.prompt(1, hint: "⇧← to answer"))
                opener.schedule()
                await clock.advance(by: .milliseconds(150))
                await Task.megaYield()
                #expect(sent == [1])
                current = try #require(Self.prompt(1, hint: "Shift + Left to answer"))
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent == [1])
            }
        }
    }

    @Test("Synchronized redraws preserve the deadline and wait for frame completion")
    func synchronizedRedraws() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var frameComplete = true
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    isFrameComplete: { frameComplete },
                    readPrompt: {
                        #expect(frameComplete)
                        return Self.prompt(1)
                    },
                    enqueue: { count, complete in
                        #expect(frameComplete)
                        sent.append(count)
                        complete(true)
                        return true
                    }
                )
                defer { opener.invalidate() }
                opener.schedule()
                for _ in 0..<3 {
                    frameComplete = false
                    opener.schedule()
                    await clock.advance(by: .milliseconds(80))
                    frameComplete = true
                    opener.schedule()
                    await clock.advance(by: .milliseconds(20))
                }
                frameComplete = false
                opener.schedule()
                await clock.advance(by: .milliseconds(80)) // Deadline at 350 ms, mid-frame.
                #expect(sent.isEmpty)
                frameComplete = true
                opener.schedule()
                #expect(sent == [1]) // No new 350 ms delay.
                for _ in 0..<5 {
                    frameComplete = false
                    opener.schedule()
                    await clock.advance(by: .milliseconds(80))
                    frameComplete = true
                    opener.schedule()
                    await clock.advance(by: .milliseconds(20))
                }
                #expect(sent == [1])
            }
        }
    }

    @Test("A completed frame must still have the same eligible prompt", arguments: [false, true])
    func changedFrame(losesEligibility: Bool) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var frameComplete = true
                var current = Self.prompt(1)
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    isFrameComplete: { frameComplete }, readPrompt: { current },
                    enqueue: { count, complete in sent.append(count)
                        complete(true)
                        return true
                    }
                )
                defer { opener.invalidate() }
                opener.schedule()
                frameComplete = false
                await clock.advance(by: .milliseconds(350))
                current = losesEligibility ? nil : Self.prompt(2)
                frameComplete = true
                opener.schedule()
                #expect(sent.isEmpty)
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(sent == (losesEligibility ? [] : [2]))
            }
        }
    }

    @Test("Cancellation, new identity and teardown discard a check waiting for a frame", arguments: ["input", "identity", "teardown"])
    func cancelDeferredFrame(reason: String) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var frameComplete = true
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    isFrameComplete: { frameComplete }, readPrompt: { Self.prompt(1) },
                    enqueue: { count, complete in sent.append(count)
                        complete(true)
                        return true
                    }
                )
                defer { opener.invalidate() }
                opener.schedule()
                frameComplete = false
                await clock.advance(by: .milliseconds(350))
                switch reason {
                case "input": opener.cancelPending()
                case "identity": opener.updateQuestionID("next-question")
                default: opener.invalidate()
                }
                frameComplete = true
                opener.schedule()
                #expect(sent.isEmpty)
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(sent == (reason == "teardown" ? [] : [1]))
            }
        }
    }

    @Test("A partial first frame cannot start a stability check")
    func partialFirstFrame() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var frameComplete = false
                var sent: [Int] = []
                let opener = TerminalCodexQuestionExpansion(
                    isFrameComplete: { frameComplete },
                    readPrompt: {
                        #expect(frameComplete)
                        return Self.prompt(1)
                    },
                    enqueue: { count, complete in sent.append(count)
                        complete(true)
                        return true
                    }
                )
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .seconds(1))
                frameComplete = true
                opener.schedule()
                await clock.advance(by: .milliseconds(349))
                #expect(sent.isEmpty)
                await clock.advance(by: .milliseconds(1))
                await Task.megaYield()
                #expect(sent == [1])
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
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { count, complete in sent.append(count)
                    complete(true)
                    return true
                })
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
                    enqueue: { count, complete in sent.append(count)
                        complete(true)
                        return true
                    }
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
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { count, complete in sent.append(count)
                    complete(true)
                    return true
                })
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
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { count, complete in
                    sent.append(count)
                    if host.observe(count) {
                        opened.append(count)
                    }
                    complete(true)
                    return true
                })
                defer { opener.invalidate() }
                for count in [4, 4, 3, 4, 0, 1] {
                    current = nil // Expanded form or intervening output.
                    opener.schedule()
                    current = Self.prompt(count, hint: "shift+← to answer")
                    opener.schedule()
                    await clock.advance(by: .milliseconds(350))
                    await Task.megaYield()
                }
                #expect(sent == [4, 3, 4, 0, 1])
                #expect(opened == [4, 4, 1])
                let remounted = TerminalCodexQuestionExpansion(readPrompt: { current }, enqueue: { count, complete in
                    if host.observe(count) {
                        opened.append(count)
                    }
                    complete(true)
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
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { _, complete in
                    attempts += 1
                    if ready {
                        complete(true)
                    }
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
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { count, complete in sent.append(count)
                    complete(true)
                    return true
                })
                opener.schedule()
                opener.invalidate()
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent.isEmpty)
            }
        }
    }

    @Test("An enqueued but rejected opener can retry the same footer on a later event")
    func rejectedAcknowledgement() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var attempts = 0
                var complete: (@MainActor (Bool) -> Void)?
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { _, result in
                    attempts += 1
                    complete = result
                    return true
                })
                defer { opener.invalidate() }
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(attempts == 1)
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(attempts == 1) // Still waiting for the first Host result.
                complete?(false)
                await clock.advance(by: .seconds(5))
                #expect(attempts == 1) // No polling after rejection.
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(attempts == 2)
                complete?(true)
                opener.schedule() // An Escape/redraw must not reopen it.
                await clock.advance(by: .seconds(1))
                #expect(attempts == 2)
            }
        }
    }

    @Test("A delayed acknowledgement observes the next queue, but cannot revive a dismantled pane")
    func delayedAcknowledgement() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                let current = LockIsolated(Self.prompt(1))
                var sent: [Int] = []
                var complete: (@MainActor (Bool) -> Void)?
                let opener = TerminalCodexQuestionExpansion(readPrompt: { current.value }, enqueue: { count, result in
                    sent.append(count)
                    complete = result
                    return true
                })
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                current.setValue(Self.prompt(0))
                opener.schedule()
                complete?(true)
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(sent == [1, 0])
                current.setValue(Self.prompt(2))
                opener.invalidate()
                complete?(false)
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(sent == [1, 0])
            }
        }
    }

    @Test("A new question identity opens at the same count without an observed empty queue")
    func consecutiveIdentities() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var sends = 0
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { _, complete in
                    sends += 1
                    complete(true)
                    return true
                })
                defer { opener.invalidate() }
                for id in ["a", "a", "b", "b"] {
                    opener.updateQuestionID(id)
                    opener.schedule()
                    await clock.advance(by: .milliseconds(350))
                    await Task.megaYield()
                }
                #expect(sends == 2)
            }
        }
    }

    @Test("Old in-flight replies cannot mark a new question at the same count as handled", arguments: [true, false])
    func staleIdentityAcknowledgement(handled: Bool) async {
        await withMainSerialExecutor {
            let clock = TestClock()
            await withDependencies { $0.continuousClock = clock } operation: {
                var replies: [@MainActor (Bool) -> Void] = []
                let opener = TerminalCodexQuestionExpansion(readPrompt: { Self.prompt(1) }, enqueue: { _, complete in
                    replies.append(complete)
                    return true
                })
                defer { opener.invalidate() }
                opener.updateQuestionID("a")
                opener.schedule()
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(replies.count == 1)
                opener.updateQuestionID("b")
                opener.schedule()
                replies.first?(handled)
                await clock.advance(by: .milliseconds(350))
                await Task.megaYield()
                #expect(replies.count == 2)
                replies.last?(true)
                opener.updateQuestionID("b") // Repeated snapshot / Escape.
                opener.schedule()
                await clock.advance(by: .seconds(1))
                #expect(replies.count == 2)
            }
        }
    }
}
