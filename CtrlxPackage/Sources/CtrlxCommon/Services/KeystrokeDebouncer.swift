import CtrlxNetworking
import Dependencies
import Foundation

/// Accumulates rapid keystrokes and flushes them within a bounded time window.
///
/// Shared between iOS and macOS viewer terminal views. The window starts with the
/// first key and never slides, so continuous typing cannot postpone transmission
/// indefinitely. The send chain preserves ordering without waiting for the
/// round-trip response.
///
/// ## Ordering guarantee
///
/// A single `sendTask` drains a FIFO queue of send operations. Each flush or
/// raw-input call appends to the queue and signals the task. Because only one
/// task reads from the queue, WebSocket writes are strictly ordered even when
/// multiple flush timers fire close together (Swift does not guarantee FIFO
/// scheduling of `@MainActor` continuations).
@MainActor
final public class KeystrokeDebouncer {
    /// Maximum time the oldest buffered key may wait before entering the send queue.
    /// The FIFO send loop, rather than a long sliding debounce, is responsible for
    /// preserving order across batches.
    static let defaultDebounceInterval: Duration = .milliseconds(10)

    private let paneId: String
    private let debounceInterval: Duration
    private let sendOp: @MainActor (SendOp) async -> Void

    @Dependency(\.continuousClock) private var clock

    private var keyBuffer: [TmuxKey] = []
    private var flushTask: Task<Void, Never>?

    /// FIFO queue of operations for the send task.
    private var sendQueue: [SendOp] = []
    private var sendTask: Task<Void, Never>?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    /// Operation queued for sending. Internal so tests can match against the
    /// values pulled out of the queue.
    enum SendOp: Equatable {
        case keys([TmuxKey])
        case rawInput(Data)
        case expandCodexQuestions(Int)
    }

    public convenience init(paneId: String, relayClient: ViewerRelayClient) {
        self.init(paneId: paneId) { op in
            switch op {
            case let .keys(keys):
                _ = await relayClient.sendCommand(SendKeystroke(keys), paneId: paneId)
            case let .rawInput(data):
                _ = await relayClient.sendCommand(SendRawInput(data: data), paneId: paneId)
            case let .expandCodexQuestions(count):
                _ = await relayClient.sendCommand(ExpandCodexQuestions(expectedCount: count), paneId: paneId)
            }
        }
    }

    /// Internal initialiser used by tests to capture send operations without
    /// standing up a full `ViewerRelayClient`. The debounce interval is also
    /// exposed here so tests can pin it to a known value driven by `TestClock`.
    init(
        paneId: String,
        debounceInterval: Duration = KeystrokeDebouncer.defaultDebounceInterval,
        sendOp: @escaping @MainActor (SendOp) async -> Void
    ) {
        self.paneId = paneId
        self.debounceInterval = debounceInterval
        self.sendOp = sendOp
        startSendLoop()
    }

    /// Add keys to the current bounded batch.
    ///
    /// Only the first key schedules the flush. Later keys join that batch without
    /// moving its deadline, which keeps latency bounded during continuous typing.
    public func enqueue(_ keys: [TmuxKey]) {
        keyBuffer.append(contentsOf: keys)

        guard flushTask == nil else { return }

        let interval = debounceInterval
        flushTask = Task(priority: .userInitiated) { [weak self] in
            do {
                try await self?.clock.sleep(for: interval)
            } catch {
                return
            }
            self?.flushTask = nil
            self?.flushBuffer()
        }
    }

    /// Sends a complete key batch without the time-based batching window.
    ///
    /// macOS first coalesces SwiftTerm's synchronous Meta/Option callbacks on
    /// the current runloop turn, so waiting another 10 ms here adds latency but
    /// cannot improve the batch. Pending timed keys are flushed ahead of this
    /// batch to preserve FIFO ordering.
    public func enqueueImmediately(_ keys: [TmuxKey]) {
        guard !keys.isEmpty else { return }
        flushTask?.cancel()
        flushTask = nil
        flushBuffer()
        enqueueSendOp(.keys(keys))
    }

    /// Immediately flush any buffered keystrokes, then send raw bytes
    /// (e.g., mouse escape sequences).
    ///
    /// Raw input is not debounced — it's already batched by the scroll event
    /// overlay — but it goes through the send queue to preserve ordering with
    /// keystrokes.
    public func enqueueRawInput(_ data: Data) {
        flushTask?.cancel()
        flushTask = nil
        flushBuffer()
        enqueueSendOp(.rawInput(data))
    }

    /// The guarded opener must follow already typed keys, not race them via a
    /// second relay send task. Like keys, it does not wait for a round trip.
    public func enqueueCodexQuestionExpansion(expectedCount: Int) {
        flushTask?.cancel()
        flushTask = nil
        flushBuffer()
        enqueueSendOp(.expandCodexQuestions(expectedCount))
    }

    /// Cancel any pending debounce and in-flight sends.
    public func cancelAll() {
        flushTask?.cancel()
        flushTask = nil
        keyBuffer.removeAll()
        sendQueue.removeAll()
        sendTask?.cancel()
        sendTask = nil
        if let cont = sendContinuation {
            sendContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Private

    /// Move buffered keys into the send queue.
    private func flushBuffer() {
        guard !keyBuffer.isEmpty else { return }
        let keys = keyBuffer
        keyBuffer.removeAll()
        enqueueSendOp(.keys(keys))
    }

    /// Append an operation and wake the send loop.
    private func enqueueSendOp(_ op: SendOp) {
        sendQueue.append(op)
        if sendTask == nil {
            startSendLoop()
            return
        }
        if let cont = sendContinuation {
            sendContinuation = nil
            cont.resume()
        }
    }

    /// Long-running task that drains the send queue in FIFO order.
    private func startSendLoop() {
        guard sendTask == nil else { return }
        sendTask = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if self.sendQueue.isEmpty {
                    // Park until enqueueSendOp wakes us.
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        self.sendContinuation = cont
                    }
                    continue
                }

                let op = self.sendQueue.removeFirst()
                await self.sendOp(op)
            }
        }
    }
}
