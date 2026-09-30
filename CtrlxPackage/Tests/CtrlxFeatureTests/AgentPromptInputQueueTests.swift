import Clocks
import ConcurrencyExtras
import CtrlxNetworking
import Dependencies
import Foundation
import Testing
@testable import CtrlxCommon
@testable import CtrlxFeature

@MainActor
@Suite("Prompt monitoring follows the input queue")
struct AgentPromptInputQueueTests {
    private final class Recorder {
        var input = AgentPromptInputAccumulator()
        var submissions: [Bool] = []
        var pastes = 0

        func keys(_ keys: [TmuxKey]) {
            let submitted = input.consume(keys)
            if keys.contains(.enter) { submissions.append(submitted) }
        }

        func paste(_ text: String) {
            input.recordPaste(text)
            pastes += 1
        }
    }

    @Test("Only acknowledged paste edits the draft before a queued Enter",
          arguments: [true, false], [true, false])
    func pasteThenEnter(pasteSucceeds: Bool, hasExistingDraft: Bool) async {
        await withMainSerialExecutor {
            await withDependencies {
                $0.continuousClock = TestClock()
            } operation: {
                let recorder = Recorder()
                let (gate, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                let queue = KeystrokeDebouncer(paneId: "%7") { op in
                    if case .pasteText = op {
                        for await _ in gate { break }
                        return pasteSucceeds
                    }
                    return true
                }
                defer { queue.cancelAll() }
                if hasExistingDraft {
                    queue.enqueue([.text("existing draft")]) { recorder.keys([.text("existing draft")]) }
                }
                queue.enqueuePasteText("first\r\nsecond\n") { recorder.paste("first\r\nsecond\n") }
                queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
                await Task.megaYield()
                #expect(recorder.pastes == 0)
                #expect(recorder.submissions.isEmpty)

                release.yield()
                await Task.megaYield()
                #expect(recorder.pastes == (pasteSucceeds ? 1 : 0))
                // A rejected paste neither creates a phantom draft nor clears
                // legitimate typing that was already sent before it.
                #expect(recorder.submissions == [pasteSucceeds || hasExistingDraft])
                queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
                await Task.megaYield()
                #expect(recorder.submissions == [pasteSucceeds || hasExistingDraft, false])
            }
        }
    }

    @Test("Coalesced key observers preserve edit order and ignore failed sends", arguments: [true, false])
    func coalescedKeys(succeeds: Bool) async {
        await withMainSerialExecutor {
            await withDependencies {
                $0.continuousClock = TestClock()
            } operation: {
                let recorder = Recorder()
                let queue = KeystrokeDebouncer(paneId: "%7") { op in
                    op == .keys([.enter]) || succeeds
                }
                defer { queue.cancelAll() }
                queue.enqueue([.text("draft")]) { recorder.keys([.text("draft")]) }
                queue.enqueue([.ctrl("u")]) { recorder.keys([.ctrl("u")]) }
                queue.enqueue([.text("new")]) { recorder.keys([.text("new")]) }
                queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
                await Task.megaYield()
                #expect(recorder.submissions == [succeeds])
                // Failed text must not remain in the accumulator either.
                queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
                await Task.megaYield()
                #expect(recorder.submissions.last == false)
            }
        }
    }

    @Test("A slash command resets the draft after the preceding paste, without submitting it")
    func commandAfterPaste() async {
        await withMainSerialExecutor {
            let recorder = Recorder()
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            let queue = KeystrokeDebouncer(paneId: "%7") { op in
                if case .pasteText = op {
                    for await _ in gate { break }
                }
                return true
            }
            defer { queue.cancelAll() }
            queue.enqueuePasteText("draft\n") { recorder.paste("draft\n") }
            queue.enqueueImmediately([.text("/model"), .delay(200), .enter]) {
                recorder.input = AgentPromptInputAccumulator()
            }
            queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
            await Task.megaYield()
            #expect(recorder.submissions.isEmpty)
            release.yield()
            await Task.megaYield()
            #expect(recorder.pastes == 1)
            #expect(recorder.submissions == [false])
        }
    }

    @Test("Cancelling a pending paste drops its observer, even if its send returns success later")
    func cancelledPaste() async {
        await withMainSerialExecutor {
            let recorder = Recorder()
            let (gate, release) = AsyncStream<Void>.makeStream()
            defer { release.finish() }
            var started = false
            let queue = KeystrokeDebouncer(paneId: "%7") { op in
                if case .pasteText = op {
                    started = true
                    for await _ in gate { break }
                }
                return true
            }
            defer { queue.cancelAll() }
            queue.enqueuePasteText("stale draft") { recorder.paste("stale draft") }
            queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
            await Task.megaYield()
            #expect(started)
            queue.cancelAll()
            queue.enqueueImmediately([.enter]) { recorder.keys([.enter]) }
            release.yield()
            await Task.megaYield()
            #expect(recorder.pastes == 0)
            #expect(recorder.submissions == [false])
        }
    }
}
