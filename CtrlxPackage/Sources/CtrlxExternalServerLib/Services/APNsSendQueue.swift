import CtrlxNetworking
import Logging
import NIOCore

/// APNs latency must never hold up a Host's ordered WebSocket receiver.
actor APNsSendQueue {
    private struct Pending {
        let payload: EncryptedPushPayload
        let pairId: String
        let byteCount: Int
    }

    private let send: @Sendable (EncryptedPushPayload, String) async -> Void
    private let maximumPendingCount: Int
    private let maximumPendingBytes: Int
    private let sendTimeout: Duration
    private let logger = Logger(label: "apns-send-queue")
    private var pending = CircularBuffer<Pending>()
    private var pendingBytes = 0
    private var worker: Task<Void, Never>?
    private var stopped = false

    init(
        maximumPendingCount: Int = 256,
        maximumPendingBytes: Int = 1_048_576,
        sendTimeout: Duration = .seconds(15),
        send: @escaping @Sendable (EncryptedPushPayload, String) async -> Void
    ) {
        self.maximumPendingCount = maximumPendingCount
        self.maximumPendingBytes = maximumPendingBytes
        self.sendTimeout = sendTimeout
        self.send = send
    }

    @discardableResult
    func enqueue(payload: EncryptedPushPayload, pairId: String) -> Bool {
        guard !stopped else { return false }
        let byteCount = payload.encryptedContent.ciphertext.count
            + payload.encryptedContent.senderKeyId.utf8.count
            + payload.pairId.utf8.count + pairId.utf8.count
        guard
            pending.count < maximumPendingCount,
            byteCount <= maximumPendingBytes - pendingBytes
        else {
            logger.error("APNs queue full; rejecting push", metadata: ["pairId": "\(pairId)"])
            return false
        }
        pending.append(.init(payload: payload, pairId: pairId, byteCount: byteCount))
        pendingBytes += byteCount
        if worker == nil {
            worker = Task { await drain() }
        }
        return true
    }

    private func drain() async {
        defer { worker = nil }
        while !Task.isCancelled, !pending.isEmpty {
            let next = pending.removeFirst()
            pendingBytes -= next.byteCount
            await sendWithTimeout(next)
        }
    }

    private func sendWithTimeout(_ next: Pending) async {
        let deadline = ContinuousClock.now.advanced(by: sendTimeout)
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { [send] in
                guard !Task.isCancelled else { return false }
                await send(next.payload, next.pairId)
                return false
            }
            group.addTask {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    return true
                } catch {
                    return false // Send completion or shutdown cancelled the timer.
                }
            }
            let timedOut = await group.next() ?? false
            group.cancelAll()
            // APNs' HTTP client cooperates with cancellation. Join it before
            // sending the next push so timed-out sends cannot overlap later ones.
            return timedOut
        }
        if timedOut, !Task.isCancelled {
            logger.error("APNs send timed out; continuing without retry", metadata: [
                "pairId": "\(next.pairId)", "timeout": "\(sendTimeout)",
            ])
        }
    }

    func shutdown() async {
        stopped = true
        pending.removeAll()
        pendingBytes = 0
        worker?.cancel()
        await worker?.value
    }
}
