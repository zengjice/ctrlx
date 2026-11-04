import CtrlxNetworking
import Foundation
import Synchronization
import Testing
@testable import CtrlxExternalServerLib

@Suite("APNs ordered send queue", .timeLimit(.minutes(1)))
struct APNsSendQueueTests {
    @Test("A timed-out push is cancelled before the next push is sent, without retry")
    func timeoutContinuesQueue() async {
        let entered = AsyncStream<Void>.makeStream()
        let blocked = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        let events = Mutex<[String]>([])
        let queue = APNsSendQueue(sendTimeout: .milliseconds(100)) { payload, pairId in
            let text = String(decoding: payload.encryptedContent.ciphertext, as: UTF8.self)
            events.withLock { $0.append("start:\(pairId):\(text)") }
            if text == "stuck" {
                entered.continuation.yield()
                for await _ in blocked.stream {
                    break
                }
                #expect(Task.isCancelled)
                events.withLock { $0.append("cancelled:\(pairId)") }
            } else {
                events.withLock { $0.append("finished:\(pairId)") }
                finished.continuation.yield()
            }
        }
        #expect(await queue.enqueue(payload: push("stuck"), pairId: "first-device"))
        for await _ in entered.stream {
            break
        }
        #expect(await queue.enqueue(payload: push("next"), pairId: "second-device"))
        for await _ in finished.stream {
            break
        }
        await queue.shutdown()
        #expect(events.withLock { $0 } == [
            "start:first-device:stuck", "cancelled:first-device",
            "start:second-device:next", "finished:second-device",
        ])
    }

    @Test("Completed sends cancel their timers and immediately release the queue")
    func completionCancelsTimeout() async {
        let sent = Mutex<[String]>([])
        let queue = APNsSendQueue(sendTimeout: .seconds(30)) { payload, _ in
            sent.withLock { $0.append(String(decoding: payload.encryptedContent.ciphertext, as: UTF8.self)) }
        }
        #expect(await queue.enqueue(payload: push("first"), pairId: ""))
        #expect(await queue.enqueue(payload: push("second"), pairId: ""))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while sent.withLock({ $0.count }) < 2, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(sent.withLock { $0 } == ["first", "second"])
        await queue.shutdown()
    }

    @Test("Queue bounds reject new pushes without dropping or reordering admitted pushes", arguments: [false, true])
    func boundedQueue(byteLimit: Bool) async {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        let sent = Mutex<[String]>([])
        let queue = APNsSendQueue(
            maximumPendingCount: byteLimit ? 256 : 1,
            maximumPendingBytes: byteLimit ? 1 : 1_048_576
        ) { payload, _ in
            let text = String(decoding: payload.encryptedContent.ciphertext, as: UTF8.self)
            sent.withLock { $0.append(text) }
            if text == "a" {
                entered.continuation.yield()
                for await _ in release.stream {
                    break
                }
            }
            if text == "b" {
                finished.continuation.yield()
            }
        }
        #expect(await queue.enqueue(payload: push("a"), pairId: ""))
        for await _ in entered.stream {
            break
        }
        #expect(await queue.enqueue(payload: push("b"), pairId: ""))
        #expect(await !queue.enqueue(payload: push("c"), pairId: ""))
        #expect(sent.withLock { $0 } == ["a"])
        release.continuation.finish()
        for await _ in finished.stream {
            break
        }
        await queue.shutdown()
        #expect(sent.withLock { $0 } == ["a", "b"])
    }

    @Test("Shutdown cancels the active send, discards pending pushes and refuses new work")
    func shutdown() async {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let sent = Mutex<[String]>([])
        let cancelled = Mutex(false)
        let queue = APNsSendQueue { payload, _ in
            sent.withLock { $0.append(String(decoding: payload.encryptedContent.ciphertext, as: UTF8.self)) }
            entered.continuation.yield()
            for await _ in release.stream {
                break
            }
            cancelled.withLock { $0 = Task.isCancelled }
        }
        #expect(await queue.enqueue(payload: push("active"), pairId: ""))
        for await _ in entered.stream {
            break
        }
        #expect(await queue.enqueue(payload: push("pending"), pairId: ""))
        await queue.shutdown()
        #expect(cancelled.withLock { $0 })
        #expect(await !queue.enqueue(payload: push("late"), pairId: ""))
        #expect(sent.withLock { $0 } == ["active"])
        await queue.shutdown()
    }

    private func push(_ text: String) -> EncryptedPushPayload {
        .init(encryptedContent: .init(ciphertext: Data(text.utf8), senderKeyId: ""), pairId: "")
    }
}
