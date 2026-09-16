import CtrlxNetworking
import Clocks
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon

@Suite("KeystrokeDebouncer")
@MainActor
struct KeystrokeDebouncerTests {
    @Test("Native quote edits, toolbar navigation and subsequent typing share FIFO order")
    func quoteCaretThenToolbar() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(paneId: "%0") { op in
                    sentOps.withValue { $0.append(op) }
                }
                defer { debouncer.cancelAll() }
                debouncer.enqueue([.text("“”"), .left, .text("你好")])
                debouncer.enqueue([.right])
                debouncer.enqueue([.text("之后")])
                debouncer.enqueueImmediately([.enter])
                await Task.megaYield()
                #expect(sentOps.value == [
                    .keys([.text("“”"), .left, .text("你好"), .right, .text("之后")]),
                    .keys([.enter]),
                ])
            }
        }
    }

    @Test("The batch deadline does not slide when more keys arrive")
    func boundedBatchWindow() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("a")])
                // A second key joins the existing batch without moving the
                // first key's deadline.
                await clock.advance(by: .milliseconds(20))
                debouncer.enqueue([.text("b")])
                #expect(sentOps.value.isEmpty)

                await clock.advance(by: .milliseconds(9))
                await Task.megaYield()
                #expect(sentOps.value.isEmpty)

                // The original 30 ms deadline flushes both keys. A sliding
                // debounce would still be waiting for the second key's deadline.
                await clock.advance(by: .milliseconds(1))
                await Task.megaYield()
                #expect(sentOps.value == [.keys([.text("a"), .text("b")])])
            }
        }
    }

    @Test("Continuous typing flushes while input is still arriving")
    func continuousTypingStillFlushes() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }

                debouncer.enqueue([.text("a")])
                await clock.advance(by: .milliseconds(10))
                debouncer.enqueue([.text("b")])
                await clock.advance(by: .milliseconds(10))
                debouncer.enqueue([.text("c")])
                await clock.advance(by: .milliseconds(10))
                await Task.megaYield()

                #expect(sentOps.value == [.keys([.text("a"), .text("b"), .text("c")])])

                debouncer.enqueue([.text("d")])
                await clock.advance(by: .milliseconds(30))
                await Task.megaYield()
                #expect(sentOps.value == [
                    .keys([.text("a"), .text("b"), .text("c")]),
                    .keys([.text("d")]),
                ])
            }
        }
    }

    @Test("Keys spaced beyond the debounce window flush as separate sends")
    func separateSendsAcrossWindow() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("a")])
                // First batch flushes after the window.
                await clock.advance(by: .milliseconds(40))
                await Task.megaYield()
                #expect(sentOps.value == [.keys([.text("a")])])

                // Second enqueue starts a fresh batch; it must not be merged
                // with the first.
                debouncer.enqueue([.text("b")])
                await clock.advance(by: .milliseconds(40))
                await Task.megaYield()
                #expect(sentOps.value == [
                    .keys([.text("a")]),
                    .keys([.text("b")]),
                ])
            }
        }
    }

    @Test("Raw input flushes any buffered keys before sending the raw bytes")
    func rawInputFlushesPendingKeys() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("x")])
                // Raw input arrives before the debounce window expires —
                // pending keys must be flushed immediately, raw bytes follow.
                debouncer.enqueueRawInput(Data([0x1B, 0x5B, 0x41]))
                await Task.megaYield()
                #expect(sentOps.value == [
                    .keys([.text("x")]),
                    .rawInput(Data([0x1B, 0x5B, 0x41])),
                ])

                // The cancelled flush timer must not fire after the window.
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(sentOps.value.count == 2)
            }
        }
    }

    @Test("Immediate batches bypass the timer and preserve pending-key order")
    func immediateBatchBypassesTimer() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .seconds(1)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }

                debouncer.enqueue([.text("pending")])
                debouncer.enqueueImmediately([.text("now")])
                await Task.megaYield()

                #expect(sentOps.value == [
                    .keys([.text("pending")]),
                    .keys([.text("now")]),
                ])

                // The cancelled timer must not emit a duplicate batch later.
                await clock.advance(by: .seconds(2))
                await Task.megaYield()
                #expect(sentOps.value.count == 2)
            }
        }
    }

    @Test("Immediate command preserves its host-side pause and Return without another send")
    func immediateCommandPreservesSubmission() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .seconds(1)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                let command: [TmuxKey] = [.text("/model"), .delay(200), .enter]
                debouncer.enqueue([.left])
                debouncer.enqueueImmediately(command)
                debouncer.enqueue([.down])
                await Task.megaYield()

                // No local clock advance or second Send tap is needed. The host
                // receives the whole submission, including its timing boundary.
                #expect(sentOps.value == [.keys([.left]), .keys(command)])

                await clock.advance(by: .seconds(2))
                await Task.megaYield()
                #expect(sentOps.value == [.keys([.left]), .keys(command), .keys([.down])])
                debouncer.cancelAll()
            }
        }
    }

    @Test("A cancelled sender restarts for the next immediate batch")
    func restartsAfterCancellation() async {
        await withMainSerialExecutor {
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            let debouncer = KeystrokeDebouncer(paneId: "%0") { op in
                sentOps.withValue { $0.append(op) }
            }

            debouncer.cancelAll()
            debouncer.enqueueImmediately([.text("current")])
            await Task.megaYield()

            #expect(sentOps.value == [.keys([.text("current")])])
        }
    }

    @Test("cancelAll drops pending keys without sending")
    func cancelAllDropsPending() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let sentOps = LockIsolated<[KeystrokeDebouncer.SendOp]>([])
            await withDependencies {
                $0.continuousClock = clock
            } operation: { @MainActor in
                let debouncer = KeystrokeDebouncer(
                    paneId: "%0",
                    debounceInterval: .milliseconds(30)
                ) { op in
                    sentOps.withValue { $0.append(op) }
                }
                debouncer.enqueue([.text("a")])
                debouncer.cancelAll()
                // Crossing the deadline after cancelAll must not emit anything.
                await clock.advance(by: .seconds(1))
                await Task.megaYield()
                #expect(sentOps.value.isEmpty)
            }
        }
    }
}
