import Foundation
import os.lock
import OSLog

/// Content-free, debug-only measurements before the terminal stream's downstream queues.
final class HostPerformanceMetrics: Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case controlIngressWait
        case outputMainActorWait
        case outputCallback
        case responseMainActorWait
        case windowGrouping
        case sessionGrouping
    }

    struct Sample: Sendable {
        let generation: UInt64
        let start: ContinuousClock.Instant
    }

    struct Timing: Sendable {
        var count = 0
        var totalMicroseconds: Int64 = 0
        var maximumMicroseconds: Int64 = 0
    }

    struct Report: Sendable {
        let queuedChunks: Int
        let queuedBytes: Int
        let maximumQueuedChunks: Int
        let maximumQueuedBytes: Int
        let timings: [Kind: Timing]
    }

    private struct Queue: Sendable {
        var chunks = 0
        var bytes = 0
    }

    private struct State: Sendable {
        var enabled = false
        var generation: UInt64 = 0
        var streams: [UUID: Queue] = [:]
        var timings: [Kind: Timing] = [:]
        var maximumQueuedChunks = 0
        var maximumQueuedBytes = 0
        var nextReport = ContinuousClock.now

        var report: Report {
            Report(
                queuedChunks: streams.values.reduce(0) { $0 + $1.chunks },
                queuedBytes: streams.values.reduce(0) { $0 + $1.bytes },
                maximumQueuedChunks: maximumQueuedChunks, maximumQueuedBytes: maximumQueuedBytes,
                timings: timings
            )
        }

        mutating func record(_ kind: Kind, since sample: Sample, now: ContinuousClock.Instant) {
            let elapsed = (now - sample.start).components
            let microseconds = max(0, elapsed.seconds * 1_000_000 + elapsed.attoseconds / 1_000_000_000_000)
            var timing = timings[kind] ?? Timing()
            timing.count += 1
            timing.totalMicroseconds += microseconds
            timing.maximumMicroseconds = max(timing.maximumMicroseconds, microseconds)
            timings[kind] = timing
        }
    }

    static let shared = HostPerformanceMetrics()
    private static let logger = Logger(subsystem: "com.jicezeng.ctrlx", category: "host-performance")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let interval: Duration
    private let emit: @Sendable (Report) -> Void

    init(interval: Duration = .seconds(10), emit: @escaping @Sendable (Report) -> Void = { report in
        let timings = Kind.allCases.map { kind in
            let value = report.timings[kind] ?? Timing()
            return "\(kind.rawValue)=\(value.count)/\(value.totalMicroseconds)us,max:\(value.maximumMicroseconds)us"
        }.joined(separator: ",")
        logger.notice("Host performance: ingress=\(report.queuedChunks)/\(report.queuedBytes)B,max:\(report.maximumQueuedChunks)/\(report.maximumQueuedBytes)B timings=\(timings, privacy: .public)")
    }) {
        self.interval = interval
        self.emit = emit
    }

    func setEnabled(_ enabled: Bool) {
        state.withLock { state in
            guard state.enabled != enabled else { return }
            state.enabled = enabled
            state.generation &+= 1
            // Keep active stream registrations; old in-flight samples cannot enter the new window.
            for id in state.streams.keys {
                state.streams[id] = Queue()
            }
            state.timings.removeAll()
            state.maximumQueuedBytes = 0
            state.maximumQueuedChunks = 0
            state.nextReport = .now.advanced(by: interval)
        }
    }

    func begin() -> Sample? {
        state.withLock { $0.enabled ? Sample(generation: $0.generation, start: .now) : nil }
    }

    func record(_ kind: Kind, since sample: Sample?) {
        guard let sample else { return }
        update { state, now in
            guard state.enabled, state.generation == sample.generation else { return }
            state.record(kind, since: sample, now: now)
        }
    }

    func openStream(_ id: UUID) {
        state.withLock { $0.streams[id] = Queue() }
    }

    func closeStream(_ id: UUID) {
        state.withLock { _ = $0.streams.removeValue(forKey: id) }
    }

    func enqueue(_ id: UUID, bytes: Int) -> Sample? {
        update { state, now in
            guard state.enabled, var queue = state.streams[id] else { return nil }
            queue.chunks += 1
            queue.bytes += bytes
            state.streams[id] = queue
            state.maximumQueuedChunks = max(state.maximumQueuedChunks, state.streams.values.reduce(0) { $0 + $1.chunks })
            state.maximumQueuedBytes = max(state.maximumQueuedBytes, state.streams.values.reduce(0) { $0 + $1.bytes })
            return Sample(generation: state.generation, start: now)
        }
    }

    func dequeue(_ id: UUID, bytes: Int, sample: Sample?) {
        guard let sample else { return }
        update { state, now in
            guard state.enabled, state.generation == sample.generation, var queue = state.streams[id] else { return }
            queue.chunks -= 1
            queue.bytes -= bytes
            state.streams[id] = queue
            state.record(.controlIngressWait, since: sample, now: now)
        }
    }

    func snapshot() -> Report {
        state.withLock { $0.report }
    }

    private func update<Result: Sendable>(_ operation: @Sendable (inout State, ContinuousClock.Instant) -> Result) -> Result {
        let now = ContinuousClock.now
        let (result, report) = state.withLock { state -> (Result, Report?) in
            let result = operation(&state, now)
            guard state.enabled, now >= state.nextReport else { return (result, nil) }
            state.nextReport = now.advanced(by: interval)
            let report = state.report
            state.timings.removeAll(keepingCapacity: true)
            state.maximumQueuedBytes = report.queuedBytes
            state.maximumQueuedChunks = report.queuedChunks
            return (result, report)
        }
        if let report {
            emit(report)
        }
        return result
    }
}
