import Foundation
import Logging
import os.lock

/// Low-overhead aggregate metrics for the terminal transport hot path.
///
/// Every mutation is an in-memory lock update. A compact debug record is emitted
/// at most once per interval, so observing a busy terminal does not add a log
/// write for every pipe read, encrypted frame, or SwiftTerm feed.
final public class TerminalTransportMetrics: Sendable {
    public enum QueueKind: String, CaseIterable, Hashable, Sendable {
        case localInput
        case pipeIngress
        case streamIngress
        case webSocketSend
        case terminalFeed
    }

    public enum TimingKind: String, CaseIterable, Hashable, Sendable {
        case encryption
        case webSocketSend
        case terminalFeed
        case rawInputSend
        case rawInputQueueWait
        case localInputToFlush
        case localInputToSend
        case localInputToWrite
        case localInputToAcknowledgement
        case localInputToOutput
        case localInputToFeed
    }

    public enum LocalInputStage: UInt8, Hashable, Sendable {
        case sendStarted = 0
        case tmuxWrite = 1
        case tmuxAcknowledged = 2
    }

    /// Opaque identifier for one local keyboard or raw-input batch.
    public struct LocalInputToken: Hashable, Sendable {
        fileprivate let id: UInt64
        fileprivate let paneId: String
    }

    public struct QueueSnapshot: Equatable, Sendable {
        public let currentDepth: Int
        public let currentBytes: Int
        public let maximumDepth: Int
        public let maximumBytes: Int
    }

    public struct TimingSnapshot: Equatable, Sendable {
        public let count: Int
        public let totalMicroseconds: Int64
        public let maximumMicroseconds: Int64
    }

    public struct Snapshot: Equatable, Sendable {
        public let queues: [QueueKind: QueueSnapshot]
        public let timings: [TimingKind: TimingSnapshot]
        public let batchCount: Int
        public let totalBatchBytes: Int
        public let maximumBatchBytes: Int
        public let resyncCount: Int
        public let pendingLocalInputCount: Int
        public let failedLocalInputCount: Int
        public let expiredLocalInputCount: Int
    }

    public static let shared = TerminalTransportMetrics(label: "app")

    private struct QueueKey: Hashable, Sendable {
        let kind: QueueKind
        let id: String
    }

    private struct QueueState: Sendable {
        var currentDepth = 0
        var currentBytes = 0
        var maximumDepth = 0
        var maximumBytes = 0
    }

    private struct TimingState: Sendable {
        var count = 0
        var totalMicroseconds: Int64 = 0
        var maximumMicroseconds: Int64 = 0
    }

    private struct LocalInputTrace: Sendable {
        let paneId: String
        let acceptedAt: ContinuousClock.Instant
        var recordedStageMask: UInt8 = 0
        var observedOutput = false
        var observedFeed = false
    }

    private struct State: Sendable {
        var queues: [QueueKey: QueueState] = [:]
        var timings: [TimingKind: TimingState] = [:]
        var batchCount = 0
        var totalBatchBytes = 0
        var maximumBatchBytes = 0
        var resyncCount = 0
        var nextLocalInputId: UInt64 = 0
        var localInputs: [UInt64: LocalInputTrace] = [:]
        var failedLocalInputCount = 0
        var expiredLocalInputCount = 0
        var nextEmission: ContinuousClock.Instant?
    }

    private static let maximumPendingLocalInputs = 256
    private static let localInputLifetime = Duration.seconds(5)

    private let label: String
    private let emissionInterval: Duration
    private let logger = Logger(label: "com.jicezeng.ctrlx.terminaltransport")
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(label: String, emissionInterval: Duration = .seconds(10)) {
        self.label = label
        self.emissionInterval = emissionInterval
    }

    public func recordQueue(
        _ kind: QueueKind,
        id: String,
        depth: Int,
        bytes: Int
    ) {
        mutate { state in
            let key = QueueKey(kind: kind, id: id)
            var queue = state.queues[key] ?? QueueState()
            queue.currentDepth = max(0, depth)
            queue.currentBytes = max(0, bytes)
            queue.maximumDepth = max(queue.maximumDepth, queue.currentDepth)
            queue.maximumBytes = max(queue.maximumBytes, queue.currentBytes)
            state.queues[key] = queue
        }
    }

    public func clearQueue(_ kind: QueueKind, id: String) {
        mutate { state in
            state.queues.removeValue(forKey: QueueKey(kind: kind, id: id))
        }
    }

    public func recordBatch(bytes: Int) {
        guard bytes > 0 else { return }
        mutate { state in
            state.batchCount += 1
            state.totalBatchBytes += bytes
            state.maximumBatchBytes = max(state.maximumBatchBytes, bytes)
        }
    }

    public func recordDuration(_ kind: TimingKind, since start: ContinuousClock.Instant) {
        let microseconds = Self.microseconds(since: start, until: .now)
        mutate { state in
            Self.addTiming(kind, microseconds: microseconds, to: &state)
        }
    }

    /// Starts one best-effort local input trace. The trace is correlated with
    /// the first later pipe output and terminal feed for the same pane. It is
    /// intentionally batch-based and bounded so diagnostics remain cheap while
    /// a terminal is busy.
    public func beginLocalInput(
        paneId: String,
        acceptedAt: ContinuousClock.Instant
    ) -> LocalInputToken {
        let now = ContinuousClock.now
        return mutate { state in
            Self.expireLocalInputs(in: &state, now: now)
            while
                state.localInputs.count >= Self.maximumPendingLocalInputs,
                let oldest = state.localInputs.min(by: { $0.value.acceptedAt < $1.value.acceptedAt })?.key {
                state.localInputs.removeValue(forKey: oldest)
                state.expiredLocalInputCount += 1
            }

            state.nextLocalInputId &+= 1
            let token = LocalInputToken(id: state.nextLocalInputId, paneId: paneId)
            state.localInputs[token.id] = LocalInputTrace(
                paneId: paneId,
                acceptedAt: acceptedAt
            )
            Self.addTiming(
                .localInputToFlush,
                microseconds: Self.microseconds(since: acceptedAt, until: now),
                to: &state
            )
            return token
        }
    }

    public func recordLocalInput(_ token: LocalInputToken, stage: LocalInputStage) {
        let now = ContinuousClock.now
        mutate { state in
            Self.expireLocalInputs(in: &state, now: now)
            guard var trace = state.localInputs[token.id], trace.paneId == token.paneId else { return }
            let stageBit = UInt8(1) << stage.rawValue
            guard trace.recordedStageMask & stageBit == 0 else { return }
            trace.recordedStageMask |= stageBit

            let kind: TimingKind = switch stage {
            case .sendStarted: .localInputToSend
            case .tmuxWrite: .localInputToWrite
            case .tmuxAcknowledged: .localInputToAcknowledgement
            }
            Self.addTiming(
                kind,
                microseconds: Self.microseconds(since: trace.acceptedAt, until: now),
                to: &state
            )
            if stage == .tmuxAcknowledged, trace.observedFeed {
                state.localInputs.removeValue(forKey: token.id)
            } else {
                state.localInputs[token.id] = trace
            }
        }
    }

    /// Marks all unobserved input batches for this pane. Pipe output is a byte
    /// stream without command IDs, so exact one-to-one correlation is impossible;
    /// batching all waiting inputs against the first later output is deterministic
    /// and avoids retaining per-keystroke state.
    public func recordLocalOutput(paneId: String) {
        let now = ContinuousClock.now
        mutate { state in
            guard !state.localInputs.isEmpty else { return }
            Self.expireLocalInputs(in: &state, now: now)
            guard !state.localInputs.isEmpty else { return }
            let writtenBit = UInt8(1) << LocalInputStage.tmuxWrite.rawValue
            for id in Array(state.localInputs.keys) {
                guard var trace = state.localInputs[id] else { continue }
                guard
                    trace.paneId == paneId,
                    !trace.observedOutput,
                    trace.recordedStageMask & writtenBit != 0
                else { continue }
                trace.observedOutput = true
                state.localInputs[id] = trace
                Self.addTiming(
                    .localInputToOutput,
                    microseconds: Self.microseconds(since: trace.acceptedAt, until: now),
                    to: &state
                )
            }
        }
    }

    /// Completes traces whose corresponding pane output has reached SwiftTerm.
    public func recordLocalFeed(paneId: String) {
        let now = ContinuousClock.now
        mutate { state in
            guard !state.localInputs.isEmpty else { return }
            Self.expireLocalInputs(in: &state, now: now)
            guard !state.localInputs.isEmpty else { return }
            for id in Array(state.localInputs.keys) {
                guard var trace = state.localInputs[id] else { continue }
                guard trace.paneId == paneId, trace.observedOutput, !trace.observedFeed else { continue }
                trace.observedFeed = true
                Self.addTiming(
                    .localInputToFeed,
                    microseconds: Self.microseconds(since: trace.acceptedAt, until: now),
                    to: &state
                )
                let acknowledgedBit = UInt8(1) << LocalInputStage.tmuxAcknowledged.rawValue
                if trace.recordedStageMask & acknowledgedBit != 0 {
                    state.localInputs.removeValue(forKey: id)
                } else {
                    state.localInputs[id] = trace
                }
            }
        }
    }

    public func failLocalInput(_ token: LocalInputToken) {
        mutate { state in
            guard state.localInputs.removeValue(forKey: token.id) != nil else { return }
            state.failedLocalInputCount += 1
        }
    }

    /// Removes input abandoned by normal view teardown without reporting a
    /// transport failure.
    public func discardLocalInput(_ token: LocalInputToken) {
        mutate { state in
            state.localInputs.removeValue(forKey: token.id)
        }
    }

    public func recordResync() {
        mutate { $0.resyncCount += 1 }
    }

    public func snapshot() -> Snapshot {
        let now = ContinuousClock.now
        return state.withLock { state in
            Self.expireLocalInputs(in: &state, now: now)
            return makeSnapshot(from: state)
        }
    }

    @discardableResult
    private func mutate<Result: Sendable>(
        _ operation: @Sendable (inout State) -> Result
    ) -> Result {
        let now = ContinuousClock.now
        let (result, report) = state.withLock { state -> (Result, Snapshot?) in
            let result = operation(&state)
            guard let next = state.nextEmission else {
                state.nextEmission = now.advanced(by: emissionInterval)
                return (result, nil)
            }
            guard now >= next else { return (result, nil) }
            state.nextEmission = now.advanced(by: emissionInterval)
            let snapshot = makeSnapshot(from: state)
            resetWindow(&state)
            return (result, snapshot)
        }

        guard let report else { return result }
        logger.debug(
            "Terminal transport metrics",
            metadata: [
                "label": "\(label)",
                "queues": "\(formatQueues(report.queues))",
                "batches": "\(report.batchCount)",
                "batchBytesTotal": "\(report.totalBatchBytes)",
                "batchBytesMax": "\(report.maximumBatchBytes)",
                "timings": "\(formatTimings(report.timings))",
                "resyncs": "\(report.resyncCount)",
                "localInputPending": "\(report.pendingLocalInputCount)",
                "localInputFailed": "\(report.failedLocalInputCount)",
                "localInputExpired": "\(report.expiredLocalInputCount)",
            ]
        )
        return result
    }

    private func makeSnapshot(from state: State) -> Snapshot {
        var queues: [QueueKind: QueueSnapshot] = [:]
        for kind in QueueKind.allCases {
            let matching = state.queues.filter { $0.key.kind == kind }.map(\.value)
            queues[kind] = QueueSnapshot(
                currentDepth: matching.reduce(0) { $0 + $1.currentDepth },
                currentBytes: matching.reduce(0) { $0 + $1.currentBytes },
                maximumDepth: matching.map(\.maximumDepth).max() ?? 0,
                maximumBytes: matching.map(\.maximumBytes).max() ?? 0
            )
        }

        var timings: [TimingKind: TimingSnapshot] = [:]
        for kind in TimingKind.allCases {
            let timing = state.timings[kind] ?? TimingState()
            timings[kind] = TimingSnapshot(
                count: timing.count,
                totalMicroseconds: timing.totalMicroseconds,
                maximumMicroseconds: timing.maximumMicroseconds
            )
        }

        return Snapshot(
            queues: queues,
            timings: timings,
            batchCount: state.batchCount,
            totalBatchBytes: state.totalBatchBytes,
            maximumBatchBytes: state.maximumBatchBytes,
            resyncCount: state.resyncCount,
            pendingLocalInputCount: state.localInputs.count,
            failedLocalInputCount: state.failedLocalInputCount,
            expiredLocalInputCount: state.expiredLocalInputCount
        )
    }

    /// Keep current gauges across reporting windows, but reset accumulated
    /// counters and maxima. Empty per-view queues are removed here so opening
    /// and closing terminals cannot grow the metrics registry forever.
    private func resetWindow(_ state: inout State) {
        state.queues = state.queues.reduce(into: [:]) { queues, entry in
            guard entry.value.currentDepth > 0 || entry.value.currentBytes > 0 else { return }
            queues[entry.key] = QueueState(
                currentDepth: entry.value.currentDepth,
                currentBytes: entry.value.currentBytes,
                maximumDepth: entry.value.currentDepth,
                maximumBytes: entry.value.currentBytes
            )
        }
        state.timings.removeAll(keepingCapacity: true)
        state.batchCount = 0
        state.totalBatchBytes = 0
        state.maximumBatchBytes = 0
        state.resyncCount = 0
        state.failedLocalInputCount = 0
        state.expiredLocalInputCount = 0
    }

    private func formatQueues(_ queues: [QueueKind: QueueSnapshot]) -> String {
        QueueKind.allCases.map { kind in
            let value = queues[kind] ?? QueueSnapshot(
                currentDepth: 0,
                currentBytes: 0,
                maximumDepth: 0,
                maximumBytes: 0
            )
            return "\(kind.rawValue)=\(value.currentDepth)/\(value.currentBytes)B,max:\(value.maximumDepth)/\(value.maximumBytes)B"
        }.joined(separator: ",")
    }

    private func formatTimings(_ timings: [TimingKind: TimingSnapshot]) -> String {
        TimingKind.allCases.map { kind in
            let value = timings[kind] ?? TimingSnapshot(count: 0, totalMicroseconds: 0, maximumMicroseconds: 0)
            return "\(kind.rawValue)=\(value.count)/\(value.totalMicroseconds)us,max:\(value.maximumMicroseconds)us"
        }.joined(separator: ",")
    }

    private static func addTiming(
        _ kind: TimingKind,
        microseconds: Int64,
        to state: inout State
    ) {
        var timing = state.timings[kind] ?? TimingState()
        timing.count += 1
        timing.totalMicroseconds += microseconds
        timing.maximumMicroseconds = max(timing.maximumMicroseconds, microseconds)
        state.timings[kind] = timing
    }

    private static func microseconds(
        since start: ContinuousClock.Instant,
        until end: ContinuousClock.Instant
    ) -> Int64 {
        let components = (end - start).components
        return max(
            0,
            components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
        )
    }

    private static func expireLocalInputs(in state: inout State, now: ContinuousClock.Instant) {
        guard !state.localInputs.isEmpty else { return }
        let expired = state.localInputs.compactMap { entry in
            now - entry.value.acceptedAt >= localInputLifetime ? entry.key : nil
        }
        guard !expired.isEmpty else { return }
        for id in expired {
            state.localInputs.removeValue(forKey: id)
        }
        state.expiredLocalInputCount += expired.count
    }
}
