import CtrlxCommon
import CtrlxNetworking
import Foundation
import Logging

enum TerminalStreamInput {
    case data(Data)
    case snapshotBoundary(viewerId: String, leaseId: UUID? = nil)
    case finishBootstrap(viewerId: String, barrierId: UUID, leaseId: UUID? = nil)
    case reset(PaneStreamManager.SubscriptionResult)
    case resyncFailed(Error)

    var byteCount: Int {
        if case let .data(data) = self {
            return data.count
        }
        return 0
    }
}

enum TerminalStreamStopReason {
    case viewerRequested
    case viewerUnavailable
    case paneClosed
    case resyncFailed(String)
    case captureFailed
    case shutdown

    var label: String {
        switch self {
        case .viewerRequested: "viewer-requested"
        case .viewerUnavailable: "viewer-unavailable"
        case .paneClosed: "pane-closed"
        case let .resyncFailed(error): "resync-failed: \(error)"
        case .captureFailed: "capture-failed"
        case .shutdown: "shutdown"
        }
    }

    var isUnexpected: Bool {
        switch self {
        case .paneClosed,
             .resyncFailed,
             .captureFailed:
            true
        case .viewerRequested,
             .viewerUnavailable,
             .shutdown:
            false
        }
    }
}

@MainActor
protocol TerminalStreamSending: AnyObject {
    func sendTerminalStream(
        _ streamMessage: TerminalStreamMessage,
        to viewerIds: Set<String>,
        leaseIDs: [String: UUID]
    ) async

    func terminalSendQueueSnapshot(for viewerId: String) -> TerminalSendQueueSnapshot
}

extension TerminalStreamSending {
    func terminalSendQueueSnapshot(for viewerId: String) -> TerminalSendQueueSnapshot {
        .empty
    }
}

extension ConnectedViewerManager: TerminalStreamSending { }

struct TerminalBootstrapTrace: Equatable, Sendable {
    static let warningThresholdMilliseconds = 1_000

    let paneId: String
    let viewerId: String
    let captureMilliseconds: Int
    let initialPayloadBytes: Int
    let queueDepth: Int
    let oldestQueueWaitMilliseconds: Int
    let initialSendMilliseconds: Int
    let totalMilliseconds: Int

    var isSlow: Bool {
        totalMilliseconds >= Self.warningThresholdMilliseconds
    }

    func logIfSlow(to logger: Logger) {
        guard isSlow else { return }
        logger.warning("Slow terminal bootstrap", metadata: [
            "paneId": "\(paneId)",
            "viewerId": "\(viewerId)",
            "captureMs": "\(captureMilliseconds)",
            "initialBytes": "\(initialPayloadBytes)",
            "queueDepth": "\(queueDepth)",
            "oldestQueueWaitMs": "\(oldestQueueWaitMilliseconds)",
            "initialSendMs": "\(initialSendMilliseconds)",
            "totalMs": "\(totalMilliseconds)",
        ])
    }
}

// MARK: - Terminal Stream Service

/// Manages live terminal streaming to connected viewers.
///
/// This service subscribes to PaneStreamManager for terminal data and forwards
/// it to viewers via the network layer. It handles data batching for efficient
/// transmission.
///
/// Usage:
/// 1. Call `startStreaming(paneId:target:...)` when a viewer requests a stream
/// 2. Data flows automatically from PaneStreamManager
/// 3. Call `stopStreaming(paneId:)` when the stream should end
@Observable
@MainActor
final public class TerminalStreamService {
    enum SnapshotKind {
        case initial
        case reset
    }

    // MARK: - Properties

    private let logger = Logger(label: "com.jicezeng.ctrlx.terminalstream")

    /// Encrypted terminal-message sender. Production uses ConnectedViewerManager;
    /// tests inject an in-memory sender without opening relay connections.
    private weak var streamSender: (any TerminalStreamSending)?

    /// Reference to the pane stream manager
    private weak var paneStreamManager: PaneStreamManager?

    /// Active streams keyed by pane ID
    private var activeStreams: [String: StreamContext] = [:]

    /// Ordered data stream for each pane — ensures strictly sequential processing
    /// of incoming terminal data, preventing interleaved flushes from reordering
    /// WebSocket messages.
    private var inputBuffers: [String: TerminalStreamInputBuffer] = [:]
    private var dataConsumerTasks: [String: Task<Void, Never>] = [:]

    /// A snapshot is a multi-message transaction: metadata followed by one or
    /// more data chunks. MainActor can run another task at every send `await`,
    /// so serialize complete snapshot transactions per pane rather than merely
    /// relying on the per-message WebSocket send chain.
    private var activeSnapshotTransactionPaneIds: Set<String> = []
    private var snapshotTransactionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    // MARK: - Batching Configuration

    /// Maximum time the oldest pending bytes wait before transmission.
    private let batchInterval: Duration = .milliseconds(16)

    /// Maximum batch size before forced send
    private let maxBatchSize = 8_192 // 8KB

    /// Snapshot history is already held offscreen until complete, so larger
    /// chunks reduce per-message encryption and WebSocket send overhead without
    /// affecting the latency of live terminal output.
    private let maxSnapshotChunkSize = 64 * 1_024

    /// Backlog beyond this point is already stale for an interactive terminal.
    /// Replace it with an authoritative snapshot instead of growing latency.
    private let streamHighWaterBytes = 512 * 1_024

    private let maximumEventsPerTurn = 32
    private let maximumBytesPerTurn = 256 * 1_024

    // MARK: - Initialization

    public init() { }

    init(
        streamSender: any TerminalStreamSending,
        activeStreams: [String: StreamContext] = [:],
        paneStreamManager: PaneStreamManager? = nil
    ) {
        self.streamSender = streamSender
        self.activeStreams = activeStreams
        self.paneStreamManager = paneStreamManager
    }

    /// Configure the service with required dependencies for multi-device support.
    ///
    /// Must be called before starting any streams.
    ///
    /// - Parameters:
    ///   - connectionManager: The ConnectedViewerManager to use for sending stream data to all viewers
    ///   - paneStreamManager: The PaneStreamManager to subscribe to for data
    public func configureWithConnectionManager(
        connectionManager: ConnectedViewerManager,
        paneStreamManager: PaneStreamManager
    ) {
        streamSender = connectionManager
        self.paneStreamManager = paneStreamManager
    }

    // MARK: - Public API

    /// Check if a pane is currently streaming.
    public func isStreaming(paneId: String) -> Bool {
        activeStreams[paneId] != nil
    }

    /// Get all pane IDs that are currently streaming.
    public var streamingPaneIds: [String] {
        Array(activeStreams.keys)
    }

    /// Start streaming a pane to viewers.
    ///
    /// Subscribes to PaneStreamManager for data and sends it to iOS.
    /// The initial content is captured atomically with the subscription,
    /// ensuring no timing gap between initial state and live updates.
    ///
    /// - Parameters:
    ///   - paneId: The pane identifier (e.g., "%1")
    ///   - target: The pane target (e.g., "mysession:0.1")
    public func startStreaming(
        paneId: String,
        target: String,
        viewerId: String,
        leaseId: UUID? = nil,
        expectedWorkspacePane: WorkspacePaneIdentity? = nil
    ) async throws {
        let bootstrapStart = ContinuousClock.now

        guard let streamSender else {
            logger.error("Connection manager not configured, cannot start streaming")
            throw StreamError.notConfigured
        }

        guard let paneStreamManager else {
            logger.error("Pane stream manager not configured, cannot start streaming")
            throw StreamError.notConfigured
        }

        if
            let context = activeStreams[paneId],
            let expectedWorkspacePane,
            !expectedWorkspacePane.isSamePane(as: context.workspaceIdentity) {
            // A delayed request must not evict a newer, healthy stream. Validate
            // its target on the live control connection before replacing ours.
            _ = try await paneStreamManager.validateStreamTarget(paneId: paneId, expected: expectedWorkspacePane)
            if activeStreams[paneId] === context {
                await stopStreaming(paneId: paneId, force: true, reason: .paneClosed)
            }
            return try await startStreaming(
                paneId: paneId, target: target, viewerId: viewerId,
                leaseId: leaseId, expectedWorkspacePane: expectedWorkspacePane
            )
        }

        // If a stream is already active for this pane, reuse its single tmux
        // subscription. Only the joining viewer is staged while the existing
        // viewers continue receiving live output.
        if let context = activeStreams[paneId] {
            guard let inputBuffer = inputBuffers[paneId] else {
                throw StreamError.paneNotAvailable
            }
            context.beginBootstrap(for: viewerId, leaseId: leaseId)
            let bootstrapLeaseIDs = context.ownership.leaseIDs

            let captureStart = ContinuousClock.now
            guard
                let current = await paneStreamManager.currentContent(
                    for: paneId,
                    expectedWorkspacePane: expectedWorkspacePane,
                    maximumSnapshotScrollbackLineLimit: TerminalScrollbackPolicy.maximumRemoteSnapshotLineLimit,
                    onSnapshotBoundary: {
                        inputBuffer.enqueueControl(.snapshotBoundary(viewerId: viewerId, leaseId: leaseId))
                    }
                ) else {
                if activeStreams[paneId] === context {
                    await stopStreaming(paneId: paneId, force: true, reason: .captureFailed)
                }
                throw StreamError.paneNotAvailable
            }
            let captureMilliseconds = Self.milliseconds(
                captureStart.duration(to: ContinuousClock.now)
            )

            guard
                activeStreams[paneId] === context,
                context.ownership.contains(viewerId, leaseId: leaseId) else {
                throw StreamError.paneNotAvailable
            }

            logger.info("Viewer subscribing to existing stream", metadata: [
                "paneId": "\(paneId)",
                "subscriberCount": "\(context.ownership.count)",
            ])

            var initialContent = current.content
            initialContent.append(await paneStreamManager.mouseModeSequences(for: paneId))
            let queue = streamSender.terminalSendQueueSnapshot(for: viewerId)
            let initialSendStart = ContinuousClock.now
            let initialPayloadBytes = await sendSnapshot(
                kind: .initial,
                paneId: paneId,
                width: current.width,
                height: current.height,
                content: initialContent,
                scrollbackLineLimit: current.scrollbackLineLimit,
                recipients: [viewerId],
                leaseIDs: bootstrapLeaseIDs
            )
            let initialSendMilliseconds = Self.milliseconds(
                initialSendStart.duration(to: ContinuousClock.now)
            )

            try await finishBootstrap(for: viewerId, context: context, paneId: paneId, leaseId: leaseId)

            logBootstrapIfSlow(
                paneId: paneId,
                viewerId: viewerId,
                captureMilliseconds: captureMilliseconds,
                initialPayloadBytes: initialPayloadBytes,
                queue: queue,
                initialSendMilliseconds: initialSendMilliseconds,
                bootstrapStart: bootstrapStart
            )

            // Live title callbacks exclude bootstrapping viewers. Send the
            // latest cached title after the viewer joins the ready set.
            if let title = paneStreamManager.terminalTitle(for: paneId) {
                let titleMessage = TerminalStreamMessage.titleChange(paneId: paneId, title: title)
                await streamSender.sendTerminalStream(titleMessage, to: [viewerId], leaseIDs: bootstrapLeaseIDs)
            }
            return
        }

        logger.info("Starting terminal stream", metadata: [
            "paneId": "\(paneId)",
            "target": "\(target)",
        ])

        // Create context for batching
        let context = StreamContext(paneId: paneId, viewerId: viewerId, leaseId: leaseId, workspaceIdentity: expectedWorkspacePane)
        let bootstrapLeaseIDs = context.ownership.leaseIDs

        // Store context BEFORE subscribing so callbacks work immediately
        activeStreams[paneId] = context

        // Start the ordered consumer before capture. While the first viewer is
        // bootstrapping, data is retained in its private buffer and cannot enter
        // the WebSocket send chain ahead of initialState.
        let inputBuffer = TerminalStreamInputBuffer(
            paneId: paneId,
            highWaterBytes: streamHighWaterBytes
        )
        inputBuffers[paneId] = inputBuffer
        dataConsumerTasks[paneId] = makeDataConsumer(
            inputBuffer: inputBuffer,
            context: context,
            paneId: paneId
        )

        // Subscribe to PaneStreamManager for data
        // This returns initial content captured atomically with the subscription
        let captureStart = ContinuousClock.now
        let result: PaneStreamManager.SubscriptionResult
        do {
            result = try await paneStreamManager.subscribe(
                paneId: paneId,
                target: target,
                expectedWorkspacePane: expectedWorkspacePane,
                maximumSnapshotScrollbackLineLimit: TerminalScrollbackPolicy.maximumRemoteSnapshotLineLimit,
                onData: { [weak self] (data: Data) in
                    guard let self else { return }
                    guard self.activeStreams[paneId] === context else { return }
                    if inputBuffer.enqueueData(data) == .resyncRequired {
                        self.requestResync(for: context, paneId: paneId)
                    }
                },
                onTitleChange: { [weak self] (title: String) in
                    guard let self else { return }
                    Task {
                        guard self.activeStreams[paneId] === context else { return }
                        await self.handleTitleChange(paneId: paneId, title: title)
                    }
                },
                onNotification: { [weak self] notification in
                    guard let self else { return }
                    Task {
                        guard self.activeStreams[paneId] === context else { return }
                        await self.handleNotification(paneId: paneId, notification: notification)
                    }
                },
                onClipboard: { [weak self] (content: String) in
                    guard let self else { return }
                    Task {
                        guard self.activeStreams[paneId] === context else { return }
                        await self.handleClipboard(paneId: paneId, content: content)
                    }
                },
                onResync: { [weak self] result in
                    guard let self, self.activeStreams[paneId] === context else { return }
                    switch result {
                    case let .success(snapshot):
                        inputBuffer.enqueueReset(snapshot)
                    case let .failure(error):
                        inputBuffer.enqueueResyncFailure(error)
                    }
                }
            )
        } catch {
            guard activeStreams[paneId] === context else { throw error }
            // Clean up on failure
            dataConsumerTasks[paneId]?.cancel()
            dataConsumerTasks.removeValue(forKey: paneId)
            inputBuffer.finish()
            inputBuffers.removeValue(forKey: paneId)
            activeStreams.removeValue(forKey: paneId)
            throw error
        }
        let captureMilliseconds = Self.milliseconds(
            captureStart.duration(to: ContinuousClock.now)
        )

        guard activeStreams[paneId] === context else {
            await paneStreamManager.unsubscribe(result.subscriptionId)
            throw StreamError.paneNotAvailable
        }
        context.subscriptionId = result.subscriptionId
        if inputBuffer.isAwaitingSnapshot {
            requestResync(for: context, paneId: paneId)
        }

        logger.info("Stream subscribed", metadata: [
            "paneId": "\(paneId)",
            "dimensions": "\(result.width)x\(result.height)",
            "bufferSize": "\(result.initialContent.count)",
        ])

        // Send the initial snapshot only to the requesting viewer. The ordered
        // consumer retains capture-time data in that viewer's bootstrap buffer.
        var initialContent = result.initialContent
        initialContent.append(await paneStreamManager.mouseModeSequences(for: paneId))
        let queue = streamSender.terminalSendQueueSnapshot(for: viewerId)
        let initialSendStart = ContinuousClock.now
        let initialPayloadBytes = await sendSnapshot(
            kind: .initial,
            paneId: paneId,
            width: result.width,
            height: result.height,
            content: initialContent,
            scrollbackLineLimit: result.scrollbackLineLimit,
            recipients: [viewerId],
            leaseIDs: bootstrapLeaseIDs
        )
        let initialSendMilliseconds = Self.milliseconds(
            initialSendStart.duration(to: ContinuousClock.now)
        )

        guard let activeContext = activeStreams[paneId], activeContext === context else {
            inputBuffer.finish()
            inputBuffers.removeValue(forKey: paneId)
            throw StreamError.paneNotAvailable
        }

        // This returns only after every pre-barrier byte has been sent. The
        // command response emitted by AppCoordinator is therefore a real ready
        // acknowledgement rather than merely "initialState was queued".
        try await finishBootstrap(for: viewerId, context: context, paneId: paneId, leaseId: leaseId)

        logBootstrapIfSlow(
            paneId: paneId,
            viewerId: viewerId,
            captureMilliseconds: captureMilliseconds,
            initialPayloadBytes: initialPayloadBytes,
            queue: queue,
            initialSendMilliseconds: initialSendMilliseconds,
            bootstrapStart: bootstrapStart
        )

        if let title = paneStreamManager.terminalTitle(for: paneId) {
            let titleMessage = TerminalStreamMessage.titleChange(paneId: paneId, title: title)
            await streamSender.sendTerminalStream(titleMessage, to: [viewerId], leaseIDs: bootstrapLeaseIDs)
        }
    }

    private func makeDataConsumer(
        inputBuffer: TerminalStreamInputBuffer,
        context: StreamContext,
        paneId: String
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in inputBuffer.wakeStream {
                guard let self else { break }
                var eventCount = 0
                var byteCount = 0

                while
                    eventCount < self.maximumEventsPerTurn,
                    byteCount < self.maximumBytesPerTurn,
                    let input = inputBuffer.dequeue() {
                    guard
                        let activeContext = self.activeStreams[paneId],
                        activeContext === context
                    else {
                        context.cancelBootstrapBarriers()
                        return
                    }

                    eventCount += 1
                    byteCount += input.byteCount
                    switch input {
                    case let .data(data):
                        await self.handleIncomingData(context: context, paneId: paneId, data: data)

                    case let .snapshotBoundary(viewerId, leaseId):
                        if context.ownership.contains(viewerId, leaseId: leaseId) {
                            context.discardBootstrapData(for: viewerId)
                        }

                    case let .finishBootstrap(viewerId, barrierId, leaseId):
                        await self.completeBootstrap(
                            for: viewerId,
                            barrierId: barrierId,
                            context: context,
                            paneId: paneId,
                            leaseId: leaseId
                        )

                    case let .reset(snapshot):
                        await self.applyReset(snapshot, context: context, paneId: paneId)

                    case let .resyncFailed(error):
                        await self.stopStreaming(
                            paneId: paneId,
                            force: true,
                            reason: .resyncFailed(error.localizedDescription)
                        )
                        return
                    }
                }

                inputBuffer.scheduleRemainingWork()
                await Task.yield()
            }
        }
    }

    private func finishBootstrap(
        for viewerId: String,
        context: StreamContext,
        paneId: String,
        leaseId: UUID?
    ) async throws {
        guard
            activeStreams[paneId] === context,
            context.ownership.contains(viewerId, leaseId: leaseId),
            let inputBuffer = inputBuffers[paneId] else {
            throw StreamError.paneNotAvailable
        }

        let barrierId = UUID()
        inputBuffer.enqueueControl(.finishBootstrap(viewerId: viewerId, barrierId: barrierId, leaseId: leaseId))
        await context.waitForBootstrapBarrier(barrierId)

        guard
            let activeContext = activeStreams[paneId],
            activeContext === context,
            context.isReady(viewerId),
            context.ownership.contains(viewerId, leaseId: leaseId)
        else {
            throw StreamError.paneNotAvailable
        }
    }

    func completeBootstrap(
        for viewerId: String,
        barrierId: UUID,
        context: StreamContext,
        paneId: String,
        leaseId: UUID? = nil
    ) async {
        defer { context.completeBootstrapBarrier(barrierId) }
        guard
            context.isBootstrapping(viewerId),
            context.ownership.contains(viewerId, leaseId: leaseId) else { return }
        let bootstrapLeaseIDs = context.ownership.leaseIDs

        // Data already batched for established viewers must be sent before the
        // ready set changes; otherwise the joining viewer would receive those
        // bytes both here and from the shared live batch.
        await flushPendingData(for: context, paneId: paneId)

        guard
            streamSender != nil,
            context.ownership.contains(viewerId, leaseId: leaseId) else { return }
        let bootstrapData = context.takeBootstrapData(for: viewerId)
        await sendDataChunks(
            bootstrapData,
            paneId: paneId,
            recipients: [viewerId],
            maximumChunkSize: maxBatchSize,
            leaseIDs: bootstrapLeaseIDs
        )

        if context.ownership.contains(viewerId, leaseId: leaseId) {
            context.finishBootstrap(for: viewerId)
        }
    }

    /// Sends snapshot metadata first, followed by bounded data chunks. The
    /// advertised byte count gives viewers an explicit completion boundary;
    /// reset chunks remain ordered ahead of subsequent live bytes.
    @discardableResult
    func sendSnapshot(
        kind: SnapshotKind,
        paneId: String,
        width: Int,
        height: Int,
        content: Data,
        scrollbackLineLimit: Int,
        recipients: Set<String>,
        leaseIDs: [String: UUID] = [:]
    ) async -> Int {
        await acquireSnapshotTransaction(for: paneId)
        defer { releaseSnapshotTransaction(for: paneId) }

        guard !Task.isCancelled else { return 0 }
        guard let streamSender else { return 0 }
        let normalizedLimit = TerminalScrollbackPolicy.normalizedLineLimit(scrollbackLineLimit)
        let metadata = switch kind {
        case .initial:
            TerminalStreamMessage.initialState(
                paneId: paneId,
                width: width,
                height: height,
                content: Data(),
                scrollbackLineLimit: normalizedLimit,
                contentByteCount: content.count
            )
        case .reset:
            TerminalStreamMessage.resetState(
                paneId: paneId,
                width: width,
                height: height,
                content: Data(),
                scrollbackLineLimit: normalizedLimit,
                contentByteCount: content.count
            )
        }
        await streamSender.sendTerminalStream(metadata, to: recipients, leaseIDs: leaseIDs)
        await sendDataChunks(
            content,
            paneId: paneId,
            recipients: recipients,
            maximumChunkSize: maxSnapshotChunkSize,
            leaseIDs: leaseIDs
        )
        return content.count
    }

    private func acquireSnapshotTransaction(for paneId: String) async {
        if activeSnapshotTransactionPaneIds.insert(paneId).inserted {
            return
        }

        await withCheckedContinuation { continuation in
            snapshotTransactionWaiters[paneId, default: []].append(continuation)
        }
    }

    private func releaseSnapshotTransaction(for paneId: String) {
        guard var waiters = snapshotTransactionWaiters[paneId], !waiters.isEmpty else {
            activeSnapshotTransactionPaneIds.remove(paneId)
            snapshotTransactionWaiters.removeValue(forKey: paneId)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            snapshotTransactionWaiters.removeValue(forKey: paneId)
        } else {
            snapshotTransactionWaiters[paneId] = waiters
        }
        next.resume()
    }

    private func sendDataChunks(
        _ data: Data,
        paneId: String,
        recipients: Set<String>,
        maximumChunkSize: Int,
        leaseIDs: [String: UUID]
    ) async {
        guard let streamSender else { return }
        var offset = data.startIndex
        while offset < data.endIndex {
            let remaining = data.distance(from: offset, to: data.endIndex)
            let end = data.index(offset, offsetBy: min(maximumChunkSize, remaining))
            let chunk = Data(data[offset..<end])
            TerminalTransportMetrics.shared.recordBatch(bytes: chunk.count)
            await streamSender.sendTerminalStream(
                .dataChunk(paneId: paneId, data: chunk),
                to: recipients,
                leaseIDs: leaseIDs
            )
            offset = end
        }
    }

    private func logBootstrapIfSlow(
        paneId: String,
        viewerId: String,
        captureMilliseconds: Int,
        initialPayloadBytes: Int,
        queue: TerminalSendQueueSnapshot,
        initialSendMilliseconds: Int,
        bootstrapStart: ContinuousClock.Instant
    ) {
        TerminalBootstrapTrace(
            paneId: paneId,
            viewerId: viewerId,
            captureMilliseconds: captureMilliseconds,
            initialPayloadBytes: initialPayloadBytes,
            queueDepth: queue.depth,
            oldestQueueWaitMilliseconds: queue.oldestWaitMilliseconds,
            initialSendMilliseconds: initialSendMilliseconds,
            totalMilliseconds: Self.milliseconds(
                bootstrapStart.duration(to: ContinuousClock.now)
            )
        ).logIfSlow(to: logger)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        return max(0, Int(milliseconds))
    }

    /// Errors that can occur during streaming
    public enum StreamError: Error {
        case notConfigured
        case paneNotAvailable
    }

    /// Stop streaming a pane.
    ///
    /// Removes the requesting viewer's ownership. Only truly stops (unsubscribes,
    /// sends streamEnd) when the last viewer leaves or when `force` is true.
    ///
    /// - Parameters:
    ///   - paneId: The pane identifier
    ///   - viewerId: Viewer releasing its ownership, or nil for forced cleanup
    ///   - leaseId: Exact modern subscription lease; nil preserves legacy semantics
    ///   - force: If true, stop immediately regardless of subscriber count (used for system cleanup)
    public func stopStreaming(
        paneId: String,
        viewerId: String? = nil,
        leaseId: UUID? = nil,
        force: Bool = false
    ) async {
        await stopStreaming(
            paneId: paneId,
            viewerId: viewerId,
            leaseId: leaseId,
            requireLeaseMatch: true,
            force: force,
            reason: .viewerRequested
        )
    }

    private func stopStreaming(
        paneId: String,
        viewerId: String? = nil,
        leaseId: UUID? = nil,
        requireLeaseMatch: Bool = true,
        force: Bool = false,
        reason: TerminalStreamStopReason
    ) async {
        guard let context = activeStreams[paneId] else {
            logger.debug("No active stream for pane \(paneId)")
            return
        }

        let endRecipients = context.ownership.subscribers
        let endLeaseIDs = context.ownership.leaseIDs

        if !force {
            guard let viewerId else {
                logger.error("Missing viewer ID when stopping terminal stream", metadata: [
                    "paneId": "\(paneId)",
                ])
                return
            }

            let removal = requireLeaseMatch
                ? context.ownership.unsubscribe(viewerId, leaseId: leaseId)
                : context.ownership.unsubscribeViewer(viewerId)
            switch removal {
            case .notSubscribed:
                logger.debug("Viewer was not subscribed to terminal stream", metadata: [
                    "paneId": "\(paneId)",
                    "viewerId": "\(viewerId)",
                ])
                return

            case .staleLease:
                logger.info("Ignoring stale terminal stream stop", metadata: [
                    "paneId": "\(paneId)",
                    "viewerId": "\(viewerId)",
                    "leaseId": "\(leaseId?.uuidString ?? "legacy")",
                ])
                return

            case let .retained(remainingSubscribers):
                context.removeViewer(viewerId)
                logger.info("Viewer unsubscribed from stream, others still watching", metadata: [
                    "paneId": "\(paneId)",
                    "remainingSubscribers": "\(remainingSubscribers)",
                ])
                return

            case .empty:
                context.removeViewer(viewerId)
            }
        }

        activeStreams.removeValue(forKey: paneId)

        let stopMetadata: Logger.Metadata = [
            "paneId": "\(paneId)",
            "reason": "\(reason.label)",
        ]
        if reason.isUnexpected {
            logger.warning("Terminal stream ended unexpectedly", metadata: stopMetadata)
        } else {
            logger.info("Stopping terminal stream", metadata: stopMetadata)
        }

        // Stop the ordered data consumer and stream
        dataConsumerTasks[paneId]?.cancel()
        dataConsumerTasks.removeValue(forKey: paneId)
        inputBuffers[paneId]?.finish()
        inputBuffers.removeValue(forKey: paneId)
        context.cancelBootstrapBarriers()
        context.finishMetrics()

        // Cancel any pending batch send. The drain below sends its bytes once.
        context.batchTask?.cancel()
        context.batchTask = nil

        // Unsubscribe from PaneStreamManager
        if let subscriptionId = context.subscriptionId {
            await paneStreamManager?.unsubscribe(subscriptionId)
        }

        // Flush any pending data
        await flushPendingData(for: context, paneId: paneId)

        // Send stream end only to viewers that owned this pane.
        guard let streamSender else { return }
        let endMessage = TerminalStreamMessage.streamEnd(paneId: paneId)
        await streamSender.sendTerminalStream(endMessage, to: endRecipients, leaseIDs: endLeaseIDs)
    }

    /// Releases every stream owned by one unavailable viewer without touching
    /// subscriptions that still have another viewer.
    public func stopStreams(for viewerId: String) async {
        let paneIds = activeStreams.compactMap { paneId, context in
            context.ownership.contains(viewerId) ? paneId : nil
        }
        for paneId in paneIds {
            await stopStreaming(
                paneId: paneId,
                viewerId: viewerId,
                requireLeaseMatch: false,
                reason: .viewerUnavailable
            )
        }
    }

    /// Stop all active streams.
    ///
    /// Called when viewers disconnect or the app is shutting down.
    /// Uses force to bypass subscriber count since this is a system-level cleanup.
    public func stopAllStreams() async {
        let paneIds = Array(activeStreams.keys)
        for paneId in paneIds {
            await stopStreaming(paneId: paneId, force: true, reason: .shutdown)
        }
    }

    /// Stops streams for panes that are no longer in the provided list.
    ///
    /// Called when panes change to clean up streams for closed panes.
    /// This sends the streamEnd message to viewer so it can close the terminal view.
    ///
    /// - Parameter currentPanes: The list of currently existing panes
    public func stopStreamsForClosedPanes(currentPanes: [PaneInfo]) async {
        let current = Dictionary(currentPanes.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
        let streamsToStop = activeStreams.filter { paneId, context in
            guard let pane = current[paneId] else { return true }
            guard let identity = context.workspaceIdentity else { return false }
            return !identity.isSamePane(as: pane.workspaceIdentity)
        }
        for (paneId, context) in streamsToStop where activeStreams[paneId] === context {
            await stopStreaming(paneId: paneId, force: true, reason: .paneClosed)
        }
    }

    // MARK: - Private Methods

    func scheduleBatchSend(for context: StreamContext, paneId: String) {
        // A fixed cadence starts with the first byte. Do not move the deadline
        // when later chunks arrive, otherwise a busy TUI can postpone delivery
        // until it stops drawing.
        guard context.batchTask == nil else { return }

        context.batchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.batchInterval)
            guard !Task.isCancelled else { return }
            context.batchTask = nil
            await self.flushPendingData(for: context, paneId: paneId)
        }
    }

    private func flushPendingData(for context: StreamContext, paneId: String) async {
        context.batchTask?.cancel()
        context.batchTask = nil
        guard let streamSender else { return }
        while context.pendingDataSize > 0 {
            let pendingBatch = context.takePendingData(maxBytes: maxBatchSize)
            guard !pendingBatch.data.isEmpty, !pendingBatch.recipients.isEmpty else { return }
            let message = TerminalStreamMessage.dataChunk(paneId: paneId, data: pendingBatch.data)
            TerminalTransportMetrics.shared.recordBatch(bytes: pendingBatch.data.count)
            await streamSender.sendTerminalStream(message, to: pendingBatch.recipients, leaseIDs: context.ownership.leaseIDs)
        }
    }

    /// Handle incoming data from PaneStreamManager
    func handleIncomingData(context: StreamContext, paneId: String, data: Data) async {
        context.appendIncomingData(data)

        // Bootstrap buffers live downstream of the ingress queue. Include them
        // in backpressure or a slow initialState send can move an unbounded
        // backlog out of the bounded queue without actually reducing latency.
        if context.maximumBufferedDataSize > streamHighWaterBytes {
            context.clearPendingDataForReset()
            if inputBuffers[paneId]?.requireResync() == .resyncRequired {
                requestResync(for: context, paneId: paneId)
            }
            return
        }

        // Check if we should send immediately (batch full) or schedule
        if context.pendingDataSize >= maxBatchSize {
            await flushPendingData(for: context, paneId: paneId)
        } else if context.pendingDataSize > 0 {
            scheduleBatchSend(for: context, paneId: paneId)
        }
    }

    private func requestResync(for context: StreamContext, paneId: String) {
        guard let subscriptionId = context.subscriptionId else { return }
        paneStreamManager?.requestResync(subscriptionId: subscriptionId)
        logger.warning("Terminal stream crossed high-water mark; requesting snapshot", metadata: [
            "paneId": "\(paneId)",
            "limitBytes": "\(streamHighWaterBytes)",
        ])
    }

    func applyReset(
        _ snapshot: PaneStreamManager.SubscriptionResult,
        context: StreamContext,
        paneId: String
    ) async {
        context.batchTask?.cancel()
        context.batchTask = nil
        context.clearPendingDataForReset()

        guard streamSender != nil else { return }
        let recipients = context.ownership.subscribers
        let leaseIDs = context.ownership.leaseIDs
        var content = snapshot.initialContent
        content.append(await paneStreamManager?.mouseModeSequences(for: paneId) ?? Data())
        await sendSnapshot(
            kind: .reset,
            paneId: paneId,
            width: snapshot.width,
            height: snapshot.height,
            content: content,
            scrollbackLineLimit: snapshot.scrollbackLineLimit,
            recipients: recipients,
            leaseIDs: leaseIDs
        )
    }

    /// Handle title change reported by a subscriber's SwiftTerm instance
    private func handleTitleChange(paneId: String, title: String) async {
        guard let context = activeStreams[paneId] else { return }
        guard let streamSender else { return }

        logger.info("Sending title change", metadata: [
            "paneId": "\(paneId)",
            "title": "\(title)",
        ])

        let message = TerminalStreamMessage.titleChange(paneId: paneId, title: title)
        await streamSender.sendTerminalStream(message, to: context.readyViewers, leaseIDs: context.ownership.leaseIDs)
    }

    /// Handle terminal notification (OSC 9/777) — forward to connected iOS viewers
    private func handleNotification(
        paneId: String,
        notification: TerminalStreamMessage.TerminalNotification
    ) async {
        guard let context = activeStreams[paneId] else { return }
        guard let streamSender else { return }

        let message = TerminalStreamMessage.notification(
            paneId: paneId,
            title: notification.title,
            body: notification.body
        )
        await streamSender.sendTerminalStream(message, to: context.readyViewers, leaseIDs: context.ownership.leaseIDs)
    }

    /// Maximum clipboard content size (1 MB) to forward to viewers.
    /// Prevents adversarial or buggy terminals from broadcasting huge payloads.
    private static let maxClipboardSize = 1_048_576

    /// Handle clipboard content (OSC 52) — forward to connected viewers
    private func handleClipboard(paneId: String, content: String) async {
        guard let context = activeStreams[paneId] else { return }
        guard let streamSender else { return }

        guard content.utf8.count <= Self.maxClipboardSize else {
            logger.warning("Dropping oversized clipboard update", metadata: [
                "paneId": "\(paneId)",
                "contentLength": "\(content.count)",
            ])
            return
        }

        logger.info("Sending clipboard update", metadata: [
            "paneId": "\(paneId)",
            "contentLength": "\(content.count)",
        ])

        let message = TerminalStreamMessage.clipboardUpdate(paneId: paneId, content: content)
        await streamSender.sendTerminalStream(message, to: context.readyViewers, leaseIDs: context.ownership.leaseIDs)
    }
}

// MARK: - Bounded Input Buffer

/// MainActor-owned queue with a byte high-water mark. Control barriers survive
/// overload; terminal data is replaced by one authoritative snapshot request.
@MainActor
final class TerminalStreamInputBuffer {
    enum EnqueueResult: Equatable {
        case enqueued
        case awaitingSnapshot
        case resyncRequired
    }

    let wakeStream: AsyncStream<Void>

    private let paneId: String
    private let highWaterBytes: Int
    private let wakeContinuation: AsyncStream<Void>.Continuation
    private var items: [TerminalStreamInput] = []
    private var headIndex = 0
    private var pendingBytes = 0
    private(set) var isAwaitingSnapshot = false

    init(paneId: String, highWaterBytes: Int) {
        precondition(highWaterBytes > 0)
        self.paneId = paneId
        self.highWaterBytes = highWaterBytes
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.wakeStream = stream
        self.wakeContinuation = continuation
    }

    var queuedBytes: Int {
        pendingBytes
    }

    var queuedDepth: Int {
        items.count - headIndex
    }

    func enqueueData(_ data: Data) -> EnqueueResult {
        guard !data.isEmpty else { return .enqueued }
        guard !isAwaitingSnapshot else { return .awaitingSnapshot }

        guard pendingBytes + data.count <= highWaterBytes else {
            retainControlItemsOnly()
            isAwaitingSnapshot = true
            recordQueue()
            return .resyncRequired
        }

        items.append(.data(data))
        pendingBytes += data.count
        recordQueue()
        wakeContinuation.yield()
        return .enqueued
    }

    func enqueueControl(_ input: TerminalStreamInput) {
        items.append(input)
        recordQueue()
        wakeContinuation.yield()
    }

    func enqueueReset(_ snapshot: PaneStreamManager.SubscriptionResult) {
        let controls = remainingControlItems()
        items = [.reset(snapshot)] + controls
        headIndex = 0
        pendingBytes = 0
        isAwaitingSnapshot = false
        recordQueue()
        wakeContinuation.yield()
    }

    func enqueueResyncFailure(_ error: Error) {
        let controls = remainingControlItems()
        items = [.resyncFailed(error)] + controls
        headIndex = 0
        pendingBytes = 0
        isAwaitingSnapshot = false
        recordQueue()
        wakeContinuation.yield()
    }

    func requireResync() -> EnqueueResult {
        guard !isAwaitingSnapshot else { return .awaitingSnapshot }
        retainControlItemsOnly()
        isAwaitingSnapshot = true
        recordQueue()
        return .resyncRequired
    }

    func dequeue() -> TerminalStreamInput? {
        guard !isAwaitingSnapshot, headIndex < items.count else { return nil }
        let input = items[headIndex]
        headIndex += 1
        pendingBytes = max(0, pendingBytes - input.byteCount)
        compactConsumedItems()
        recordQueue()
        return input
    }

    func scheduleRemainingWork() {
        guard !isAwaitingSnapshot, headIndex < items.count else { return }
        wakeContinuation.yield()
    }

    func finish() {
        wakeContinuation.finish()
        items.removeAll(keepingCapacity: false)
        headIndex = 0
        pendingBytes = 0
        isAwaitingSnapshot = false
        TerminalTransportMetrics.shared.clearQueue(.streamIngress, id: paneId)
    }

    private func retainControlItemsOnly() {
        items = remainingControlItems()
        headIndex = 0
        pendingBytes = 0
    }

    private func remainingControlItems() -> [TerminalStreamInput] {
        items[headIndex...].filter { input in
            switch input {
            case .snapshotBoundary,
                 .finishBootstrap:
                true
            case .data,
                 .reset,
                 .resyncFailed:
                false
            }
        }
    }

    private func compactConsumedItems() {
        if headIndex == items.count {
            items.removeAll(keepingCapacity: true)
            headIndex = 0
        } else if headIndex >= 32 {
            items.removeFirst(headIndex)
            headIndex = 0
        }
    }

    private func recordQueue() {
        TerminalTransportMetrics.shared.recordQueue(
            .streamIngress,
            id: paneId,
            depth: queuedDepth,
            bytes: pendingBytes
        )
    }
}

// MARK: - Stream Context

/// Context for an active terminal stream, handles data batching.
@MainActor
final class StreamContext {
    struct PendingBatch: Equatable, Sendable {
        let data: Data
        let recipients: Set<String>
    }

    let paneId: String
    let workspaceIdentity: WorkspacePaneIdentity?
    var ownership: TerminalStreamOwnership
    var subscriptionId: UUID?
    private var pendingData = Data()
    private var readyViewerIds: Set<String> = []
    private var bootstrapData: [String: Data] = [:]
    private var bootstrapBarrierWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var completedBootstrapBarriers: Set<UUID> = []
    var batchTask: Task<Void, Never>?

    var pendingDataSize: Int {
        pendingData.count
    }

    var maximumBufferedDataSize: Int {
        max(pendingData.count, bootstrapData.values.map(\.count).max() ?? 0)
    }

    init(paneId: String, viewerId: String, leaseId: UUID? = nil, workspaceIdentity: WorkspacePaneIdentity? = nil) {
        self.paneId = paneId
        self.workspaceIdentity = workspaceIdentity
        self.ownership = TerminalStreamOwnership(viewerId: viewerId, leaseId: leaseId)
        bootstrapData[viewerId] = Data()
        recordBufferedQueue()
    }

    var readyViewers: Set<String> {
        readyViewerIds
    }

    func beginBootstrap(for viewerId: String, leaseId: UUID? = nil) {
        ownership.subscribe(viewerId, leaseId: leaseId)
        readyViewerIds.remove(viewerId)
        bootstrapData[viewerId] = Data()
        recordBufferedQueue()
    }

    func isBootstrapping(_ viewerId: String) -> Bool {
        bootstrapData[viewerId] != nil
    }

    func isReady(_ viewerId: String) -> Bool {
        readyViewerIds.contains(viewerId)
    }

    func appendIncomingData(_ data: Data) {
        guard !data.isEmpty else { return }

        for viewerId in Array(bootstrapData.keys) {
            bootstrapData[viewerId]?.append(data)
        }
        if !readyViewerIds.isEmpty {
            pendingData.append(data)
        }
        recordBufferedQueue()
    }

    func flushPendingData() -> PendingBatch {
        takePendingData(maxBytes: pendingData.count)
    }

    func takePendingData(maxBytes: Int) -> PendingBatch {
        guard maxBytes > 0, !pendingData.isEmpty else {
            return PendingBatch(data: Data(), recipients: readyViewerIds)
        }
        let count = min(maxBytes, pendingData.count)
        let data = Data(pendingData.prefix(count))
        pendingData.removeFirst(count)
        recordBufferedQueue()
        return PendingBatch(data: data, recipients: readyViewerIds)
    }

    func clearPendingDataForReset() {
        pendingData = Data()
        for viewerId in Array(bootstrapData.keys) {
            bootstrapData[viewerId] = Data()
        }
        recordBufferedQueue()
    }

    func takeBootstrapData(for viewerId: String) -> Data {
        let data = bootstrapData[viewerId] ?? Data()
        bootstrapData[viewerId] = Data()
        recordBufferedQueue()
        return data
    }

    /// Discards bytes already represented by an authoritative snapshot. The
    /// callback is ordered on the same tmux control stream, so later bytes remain
    /// buffered and are replayed after the snapshot reaches this viewer.
    func discardBootstrapData(for viewerId: String) {
        guard bootstrapData[viewerId] != nil else { return }
        bootstrapData[viewerId] = Data()
        recordBufferedQueue()
    }

    func finishBootstrap(for viewerId: String) {
        guard bootstrapData.removeValue(forKey: viewerId) != nil else { return }
        recordBufferedQueue()
        guard ownership.contains(viewerId) else { return }
        readyViewerIds.insert(viewerId)
    }

    func removeViewer(_ viewerId: String) {
        readyViewerIds.remove(viewerId)
        bootstrapData.removeValue(forKey: viewerId)
        recordBufferedQueue()
    }

    func waitForBootstrapBarrier(_ barrierId: UUID) async {
        if completedBootstrapBarriers.remove(barrierId) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            bootstrapBarrierWaiters[barrierId] = continuation
        }
    }

    func completeBootstrapBarrier(_ barrierId: UUID) {
        if let continuation = bootstrapBarrierWaiters.removeValue(forKey: barrierId) {
            continuation.resume()
        } else {
            completedBootstrapBarriers.insert(barrierId)
        }
    }

    func cancelBootstrapBarriers() {
        let continuations = bootstrapBarrierWaiters.values
        bootstrapBarrierWaiters.removeAll()
        completedBootstrapBarriers.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func finishMetrics() {
        TerminalTransportMetrics.shared.clearQueue(.streamIngress, id: "\(paneId):batch")
    }

    private func recordBufferedQueue() {
        var depth = pendingData.isEmpty ? 0 : 1
        var bytes = pendingData.count
        for data in bootstrapData.values {
            if !data.isEmpty {
                depth += 1
            }
            bytes += data.count
        }
        TerminalTransportMetrics.shared.recordQueue(
            .streamIngress,
            id: "\(paneId):batch",
            depth: depth,
            bytes: bytes
        )
    }
}
