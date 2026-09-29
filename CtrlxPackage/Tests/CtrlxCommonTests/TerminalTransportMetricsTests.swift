import CtrlxCommon
import Testing

@Suite("Terminal transport metrics")
struct TerminalTransportMetricsTests {
    @Test("Queue gauges aggregate current values and preserve per-queue maxima")
    func queueAggregation() {
        let metrics = TerminalTransportMetrics(label: "test")

        metrics.recordQueue(.streamIngress, id: "%1", depth: 2, bytes: 100)
        metrics.recordQueue(.streamIngress, id: "%2", depth: 3, bytes: 200)
        metrics.recordQueue(.streamIngress, id: "%1", depth: 1, bytes: 50)

        let queue = metrics.snapshot().queues[.streamIngress]
        #expect(queue?.currentDepth == 4)
        #expect(queue?.currentBytes == 250)
        #expect(queue?.maximumDepth == 3)
        #expect(queue?.maximumBytes == 200)

        metrics.clearQueue(.streamIngress, id: "%2")
        let cleared = metrics.snapshot().queues[.streamIngress]
        #expect(cleared?.currentDepth == 1)
        #expect(cleared?.currentBytes == 50)
    }

    @Test("Batch and resync counters retain bounded-path evidence")
    func batchAndResyncCounters() {
        let metrics = TerminalTransportMetrics(label: "test")

        metrics.recordBatch(bytes: 4_096)
        metrics.recordBatch(bytes: 8_192)
        metrics.recordResync()

        let snapshot = metrics.snapshot()
        #expect(snapshot.batchCount == 2)
        #expect(snapshot.totalBatchBytes == 12_288)
        #expect(snapshot.maximumBatchBytes == 8_192)
        #expect(snapshot.resyncCount == 1)
    }

    @Test("Duration samples record count and nonnegative time")
    func durationSamples() {
        let metrics = TerminalTransportMetrics(label: "test")
        let start = ContinuousClock.now

        metrics.recordDuration(.terminalFeed, since: start)

        let timing = metrics.snapshot().timings[.terminalFeed]
        #expect(timing?.count == 1)
        #expect(timing?.totalMicroseconds ?? -1 >= 0)
        #expect(timing?.maximumMicroseconds ?? -1 >= 0)
    }

    @Test("Local input traces cover the full pane round trip")
    func localInputRoundTrip() {
        let metrics = TerminalTransportMetrics(label: "test")
        let token = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)

        metrics.recordLocalInput(token, stage: .sendStarted)
        metrics.recordLocalInput(token, stage: .tmuxWrite)
        metrics.recordLocalInput(token, stage: .tmuxAcknowledged)
        metrics.recordLocalOutput(paneId: "%1")
        metrics.recordLocalFeed(paneId: "%1")

        let snapshot = metrics.snapshot()
        #expect(snapshot.pendingLocalInputCount == 0)
        #expect(snapshot.timings[.localInputToFlush]?.count == 1)
        #expect(snapshot.timings[.localInputToSend]?.count == 1)
        #expect(snapshot.timings[.localInputToWrite]?.count == 1)
        #expect(snapshot.timings[.localInputToAcknowledgement]?.count == 1)
        #expect(snapshot.timings[.localInputToOutput]?.count == 1)
        #expect(snapshot.timings[.localInputToFeed]?.count == 1)
    }

    @Test("Raw input queue and send timings are separately aggregated")
    func rawInputTimings() {
        let metrics = TerminalTransportMetrics(label: "raw-test")
        metrics.recordDuration(.rawInputQueueWait, since: .now)
        metrics.recordDuration(.rawInputSend, since: .now)
        metrics.recordDuration(.rawInputSend, since: .now)
        #expect(metrics.snapshot().timings[.rawInputQueueWait]?.count == 1)
        #expect(metrics.snapshot().timings[.rawInputSend]?.count == 2)
    }

    @Test("Duplicate input stages are ignored")
    func duplicateLocalInputStages() {
        let metrics = TerminalTransportMetrics(label: "test")
        let token = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)

        metrics.recordLocalInput(token, stage: .tmuxWrite)
        metrics.recordLocalInput(token, stage: .tmuxWrite)

        #expect(metrics.snapshot().timings[.localInputToWrite]?.count == 1)
    }

    @Test("Output arriving before tmux acknowledgement preserves the trace")
    func outputBeforeAcknowledgement() {
        let metrics = TerminalTransportMetrics(label: "test")
        let token = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)

        metrics.recordLocalInput(token, stage: .tmuxWrite)
        metrics.recordLocalOutput(paneId: "%1")
        metrics.recordLocalFeed(paneId: "%1")
        #expect(metrics.snapshot().pendingLocalInputCount == 1)

        metrics.recordLocalInput(token, stage: .tmuxAcknowledged)
        let snapshot = metrics.snapshot()
        #expect(snapshot.pendingLocalInputCount == 0)
        #expect(snapshot.timings[.localInputToAcknowledgement]?.count == 1)
        #expect(snapshot.timings[.localInputToFeed]?.count == 1)
    }

    @Test("Unrelated pane output before tmux write is ignored")
    func outputBeforeWrite() {
        let metrics = TerminalTransportMetrics(label: "test")
        let token = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)

        metrics.recordLocalOutput(paneId: "%1")
        metrics.recordLocalFeed(paneId: "%1")
        #expect(metrics.snapshot().timings[.localInputToOutput]?.count == Int.zero)

        metrics.recordLocalInput(token, stage: .tmuxWrite)
        metrics.recordLocalOutput(paneId: "%1")
        metrics.recordLocalFeed(paneId: "%1")
        metrics.recordLocalInput(token, stage: .tmuxAcknowledged)
        #expect(metrics.snapshot().pendingLocalInputCount == 0)
    }

    @Test("Local input traces have a hard memory bound")
    func boundedLocalInputTraces() {
        let metrics = TerminalTransportMetrics(label: "test")

        for _ in 0..<300 {
            _ = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)
        }

        let snapshot = metrics.snapshot()
        #expect(snapshot.pendingLocalInputCount == 256)
        #expect(snapshot.expiredLocalInputCount == 44)
    }

    @Test("Failed input leaves no pending trace")
    func failedLocalInput() {
        let metrics = TerminalTransportMetrics(label: "test")
        let token = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)

        metrics.failLocalInput(token)

        let snapshot = metrics.snapshot()
        #expect(snapshot.pendingLocalInputCount == 0)
        #expect(snapshot.failedLocalInputCount == 1)
    }

    @Test("Discarded input is not reported as a transport failure")
    func discardedLocalInput() {
        let metrics = TerminalTransportMetrics(label: "test")
        let token = metrics.beginLocalInput(paneId: "%1", acceptedAt: .now)

        metrics.discardLocalInput(token)

        let snapshot = metrics.snapshot()
        #expect(snapshot.pendingLocalInputCount == 0)
        #expect(snapshot.failedLocalInputCount == 0)
    }

    @Test("Emission starts a fresh metrics window without losing live gauges")
    func emissionResetsWindow() {
        let metrics = TerminalTransportMetrics(label: "test", emissionInterval: .zero)

        metrics.recordQueue(.terminalFeed, id: "active", depth: 5, bytes: 500)
        metrics.recordBatch(bytes: 100)

        let snapshot = metrics.snapshot()
        #expect(snapshot.queues[.terminalFeed]?.currentDepth == 5)
        #expect(snapshot.queues[.terminalFeed]?.maximumDepth == 5)
        #expect(snapshot.batchCount == 0)
    }
}
