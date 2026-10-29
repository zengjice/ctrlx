import ConcurrencyExtras
import Foundation
import Testing
@testable import CtrlxServerFeature

struct HostPerformanceMetricsTests {
    @Test("Debug mode defaults off and drops samples from previous enable cycles")
    func debugLifetime() throws {
        let metrics = HostPerformanceMetrics()
        let stream = UUID()
        metrics.openStream(stream)
        #expect(metrics.begin() == nil)
        #expect(metrics.enqueue(stream, bytes: 100) == nil)
        #expect(metrics.snapshot().queuedBytes == 0)
        metrics.setEnabled(true)
        let stale = try #require(metrics.enqueue(stream, bytes: 100))
        metrics.setEnabled(false)
        #expect(metrics.snapshot().queuedBytes == 0)
        metrics.record(.windowGrouping, since: stale)
        #expect(metrics.snapshot().timings.isEmpty)
        metrics.setEnabled(true)
        let current = try #require(metrics.enqueue(stream, bytes: 20))
        metrics.dequeue(stream, bytes: 100, sample: stale)
        metrics.record(.windowGrouping, since: stale)
        #expect(metrics.snapshot().queuedBytes == 20)
        #expect(metrics.snapshot().timings.isEmpty)
        metrics.dequeue(stream, bytes: 20, sample: current)
        #expect(metrics.snapshot().queuedBytes == 0)
        #expect(metrics.snapshot().timings[.controlIngressWait]?.count == 1)
    }

    @Test("Ingress measures aggregate backlog, preserves maxima and retires disconnected streams")
    func ingressBacklog() throws {
        let metrics = HostPerformanceMetrics()
        metrics.setEnabled(true)
        let first = UUID(), second = UUID()
        metrics.openStream(first)
        metrics.openStream(second)
        let a = try #require(metrics.enqueue(first, bytes: 100))
        let b = try #require(metrics.enqueue(second, bytes: 200))
        #expect(metrics.snapshot().queuedChunks == 2)
        #expect(metrics.snapshot().maximumQueuedBytes == 300)
        metrics.dequeue(first, bytes: 100, sample: a)
        #expect(metrics.snapshot().queuedBytes == 200)
        metrics.closeStream(second)
        #expect(metrics.enqueue(second, bytes: 50) == nil)
        metrics.dequeue(second, bytes: 200, sample: b)
        let report = metrics.snapshot()
        #expect(report.queuedBytes == 0 && report.queuedChunks == 0)
        #expect(report.maximumQueuedBytes == 300 && report.maximumQueuedChunks == 2)
        #expect(report.timings[.controlIngressWait]?.count == 1)
    }

    @Test("Reporting resets interval counters while retaining live ingress gauges")
    func reporting() throws {
        let reports = LockIsolated<[HostPerformanceMetrics.Report]>([])
        let metrics = HostPerformanceMetrics(interval: .zero) { report in reports.withValue { $0.append(report) } }
        metrics.setEnabled(true)
        let stream = UUID()
        metrics.openStream(stream)
        _ = metrics.enqueue(stream, bytes: 80)
        #expect(reports.value.count == 1)
        #expect(metrics.snapshot().queuedBytes == 80)
        let sample = try #require(metrics.begin())
        metrics.record(.sessionGrouping, since: .init(generation: sample.generation, start: sample.start.advanced(by: .milliseconds(-2))))
        let report = try #require(reports.value.last)
        #expect(report.timings[.sessionGrouping]?.count == 1)
        #expect(report.timings[.sessionGrouping]?.totalMicroseconds ?? 0 >= 2_000)
        #expect(metrics.snapshot().timings.isEmpty)
        #expect(metrics.snapshot().maximumQueuedBytes == 80)
        metrics.setEnabled(false)
        metrics.record(.sessionGrouping, since: sample)
        #expect(reports.value.count == 2)
    }

    @Test("Concurrent control connections retain balanced diagnostic counters")
    func concurrentStreams() async {
        let metrics = HostPerformanceMetrics()
        metrics.setEnabled(true)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let stream = UUID()
                    metrics.openStream(stream)
                    for _ in 0..<50 {
                        let sample = metrics.enqueue(stream, bytes: 128)
                        await Task.yield()
                        metrics.dequeue(stream, bytes: 128, sample: sample)
                    }
                    metrics.closeStream(stream)
                }
            }
        }
        let report = metrics.snapshot()
        #expect(report.queuedBytes == 0 && report.queuedChunks == 0)
        #expect(report.timings[.controlIngressWait]?.count == 400)
    }
}
