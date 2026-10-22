#if os(macOS)
    import CtrlxNetworking
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    final private class CapturingTerminalStreamSender: TerminalStreamSending {
        struct Delivery {
            let message: TerminalStreamMessage
            let recipients: Set<String>
            let leaseIDs: [String: UUID]
        }

        private(set) var deliveries: [Delivery] = []

        func sendTerminalStream(
            _ streamMessage: TerminalStreamMessage,
            to viewerIds: Set<String>,
            leaseIDs: [String: UUID]
        ) async {
            deliveries.append(Delivery(message: streamMessage, recipients: viewerIds, leaseIDs: leaseIDs))
        }

        var dataDeliveries: [(data: Data, recipients: Set<String>)] {
            deliveries.compactMap { delivery in
                guard case let .dataChunk(chunk) = delivery.message.updateType else { return nil }
                return (Data(base64Encoded: chunk.dataBase64) ?? Data(), delivery.recipients)
            }
        }

        var resetDeliveries: [(state: TerminalStreamMessage.InitialState, recipients: Set<String>)] {
            deliveries.compactMap { delivery in
                guard case let .resetState(state) = delivery.message.updateType else { return nil }
                return (state, delivery.recipients)
            }
        }

        var initialDeliveries: [(state: TerminalStreamMessage.InitialState, recipients: Set<String>)] {
            deliveries.compactMap { delivery in
                guard case let .initialState(state) = delivery.message.updateType else { return nil }
                return (state, delivery.recipients)
            }
        }
    }

    @MainActor
    final private class SuspendingTerminalStreamSender: TerminalStreamSending {
        struct Delivery {
            let message: TerminalStreamMessage
            let recipients: Set<String>
            let leaseIDs: [String: UUID]
        }

        private(set) var deliveries: [Delivery] = []
        private var shouldSuspendFirstDelivery = true
        private var isFirstDeliverySuspended = false
        private var firstDeliveryContinuation: CheckedContinuation<Void, Never>?
        private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

        func sendTerminalStream(
            _ streamMessage: TerminalStreamMessage,
            to viewerIds: Set<String>,
            leaseIDs: [String: UUID]
        ) async {
            deliveries.append(Delivery(message: streamMessage, recipients: viewerIds, leaseIDs: leaseIDs))
            guard shouldSuspendFirstDelivery else { return }

            shouldSuspendFirstDelivery = false
            isFirstDeliverySuspended = true
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                firstDeliveryContinuation = continuation
            }
        }

        func waitUntilFirstDeliveryIsSuspended() async {
            if isFirstDeliverySuspended {
                return
            }
            await withCheckedContinuation { continuation in
                suspensionWaiters.append(continuation)
            }
        }

        func resumeFirstDelivery() {
            firstDeliveryContinuation?.resume()
            firstDeliveryContinuation = nil
        }

        var deliveryKinds: [String] {
            deliveries.map { delivery in
                switch delivery.message.updateType {
                case .initialState: "initial"
                case .resetState: "reset"
                case .dataChunk: "data"
                default: "other"
                }
            }
        }
    }

    @Suite("Terminal stream ownership")
    struct TerminalStreamOwnershipTests {
        @Test("Repeated starts from one viewer are idempotent")
        func duplicateSubscribe() {
            var ownership = TerminalStreamOwnership(viewerId: "viewer-a")

            let inserted = ownership.subscribe("viewer-a")
            #expect(inserted == false)
            #expect(ownership.count == 1)
        }

        @Test("The stream survives until its last viewer leaves")
        func multipleViewers() {
            var ownership = TerminalStreamOwnership(viewerId: "viewer-a")
            let inserted = ownership.subscribe("viewer-b")
            let firstRemoval = ownership.unsubscribe("viewer-a")
            let secondRemoval = ownership.unsubscribe("viewer-b")

            #expect(inserted == true)
            #expect(firstRemoval == .retained(1))
            #expect(secondRemoval == .empty)
        }

        @Test("An unknown viewer cannot release another viewer's stream")
        func unknownViewer() {
            var ownership = TerminalStreamOwnership(viewerId: "viewer-a")

            let removal = ownership.unsubscribe("viewer-b")
            #expect(removal == .notSubscribed)
            #expect(ownership.count == 1)
        }

        @Test("A stale lease cannot release a replacement subscription")
        func staleLease() {
            let oldLease = UUID()
            let newLease = UUID()
            var ownership = TerminalStreamOwnership(
                viewerId: "viewer-a",
                leaseId: oldLease
            )

            let replaced = ownership.subscribe("viewer-a", leaseId: newLease)
            let staleRemoval = ownership.unsubscribe("viewer-a", leaseId: oldLease)
            #expect(replaced)
            #expect(staleRemoval == .staleLease)
            #expect(ownership.contains("viewer-a"))
            let currentRemoval = ownership.unsubscribe("viewer-a", leaseId: newLease)
            #expect(currentRemoval == .empty)
        }

        @Test("A legacy stop cannot release a modern lease")
        func legacyStopDoesNotReleaseModernLease() {
            var ownership = TerminalStreamOwnership(
                viewerId: "viewer-a",
                leaseId: UUID()
            )

            let legacyRemoval = ownership.unsubscribe("viewer-a")
            #expect(legacyRemoval == .staleLease)
            #expect(ownership.contains("viewer-a"))
            let disconnectRemoval = ownership.unsubscribeViewer("viewer-a")
            #expect(disconnectRemoval == .empty)
        }
    }

    @Suite("Terminal stream fixed-cadence batching")
    @MainActor
    struct TerminalStreamBatchingTests {
        @Test("Service ignores an old lease after the viewer starts a replacement")
        func serviceIgnoresStaleLeaseStop() async {
            let sender = CapturingTerminalStreamSender()
            let oldLease = UUID()
            let newLease = UUID()
            let context = StreamContext(
                paneId: "%1",
                viewerId: "viewer-a",
                leaseId: oldLease
            )
            context.beginBootstrap(for: "viewer-a", leaseId: newLease)
            context.finishBootstrap(for: "viewer-a")
            let service = TerminalStreamService(
                streamSender: sender,
                activeStreams: ["%1": context]
            )

            await service.stopStreaming(
                paneId: "%1",
                viewerId: "viewer-a",
                leaseId: oldLease
            )

            #expect(service.streamingPaneIds == ["%1"])
            #expect(sender.deliveries.isEmpty)

            await service.stopStreaming(
                paneId: "%1",
                viewerId: "viewer-a",
                leaseId: newLease
            )

            #expect(service.streamingPaneIds.isEmpty)
            #expect(sender.deliveries.count == 1)
            #expect(sender.deliveries[0].recipients == ["viewer-a"])
            #expect(sender.deliveries[0].message.updateType == .streamEnd)
            #expect(sender.deliveries[0].leaseIDs == ["viewer-a": newLease])
        }

        @Test("Disconnecting one viewer preserves other viewers and panes")
        func viewerDisconnectOnlyReleasesItsOwnership() async {
            let sender = CapturingTerminalStreamSender()
            let shared = StreamContext(paneId: "%1", viewerId: "viewer-a")
            shared.beginBootstrap(for: "viewer-b")
            shared.finishBootstrap(for: "viewer-a")
            shared.finishBootstrap(for: "viewer-b")
            let exclusive = StreamContext(paneId: "%2", viewerId: "viewer-a")
            exclusive.finishBootstrap(for: "viewer-a")
            let unrelated = StreamContext(paneId: "%3", viewerId: "viewer-c")
            unrelated.finishBootstrap(for: "viewer-c")
            let service = TerminalStreamService(
                streamSender: sender,
                activeStreams: [
                    "%1": shared,
                    "%2": exclusive,
                    "%3": unrelated,
                ]
            )

            await service.stopStreams(for: "viewer-a")

            #expect(Set(service.streamingPaneIds) == ["%1", "%3"])
            #expect(!shared.ownership.contains("viewer-a"))
            #expect(shared.ownership.contains("viewer-b"))
            #expect(unrelated.ownership.contains("viewer-c"))
        }

        @Test("Later chunks keep the first scheduled deadline")
        func continuousChunksDoNotReschedule() {
            let service = TerminalStreamService()
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")

            context.appendIncomingData(Data("a".utf8))
            service.scheduleBatchSend(for: context, paneId: "%1")
            let firstTask = context.batchTask

            context.appendIncomingData(Data("b".utf8))
            service.scheduleBatchSend(for: context, paneId: "%1")

            #expect(firstTask?.isCancelled == false)
            let batch = context.flushPendingData()
            #expect(String(data: batch.data, encoding: .utf8) == "ab")
            #expect(batch.recipients == ["viewer-a"])

            context.batchTask?.cancel()
            context.batchTask = nil
        }

        @Test("Draining clears all pending bytes")
        func drainingClearsPendingBytes() {
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.appendIncomingData(Data("abc".utf8))

            #expect(context.pendingDataSize == 3)
            #expect(context.flushPendingData().data == Data("abc".utf8))
            #expect(context.pendingDataSize == 0)
            #expect(context.flushPendingData().data.isEmpty)
        }

        @Test("Bootstrapping viewer is isolated from established live batch")
        func bootstrapDataUsesPrivateBuffer() {
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.beginBootstrap(for: "viewer-b")

            context.appendIncomingData(Data("abc".utf8))

            let live = context.flushPendingData()
            #expect(live.data == Data("abc".utf8))
            #expect(live.recipients == ["viewer-a"])
            #expect(context.takeBootstrapData(for: "viewer-b") == Data("abc".utf8))
            #expect(context.takeBootstrapData(for: "viewer-b").isEmpty)

            context.finishBootstrap(for: "viewer-b")
            #expect(context.readyViewers == ["viewer-a", "viewer-b"])
        }

        @Test("Snapshot boundary drops only joining viewer's pre-snapshot bytes")
        func snapshotBoundaryDropsPreSnapshotBootstrapData() {
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.beginBootstrap(for: "viewer-b")

            context.appendIncomingData(Data("before".utf8))
            context.discardBootstrapData(for: "viewer-b")
            context.appendIncomingData(Data("after".utf8))

            #expect(context.flushPendingData().data == Data("beforeafter".utf8))
            #expect(context.takeBootstrapData(for: "viewer-b") == Data("after".utf8))
        }

        @Test("Joining viewer snapshot boundary is ordered with queued terminal data")
        func snapshotBoundaryIsAnOrderedInputEvent() {
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.beginBootstrap(for: "viewer-b")
            let inputBuffer = TerminalStreamInputBuffer(paneId: "%1", highWaterBytes: 1_024)

            #expect(inputBuffer.enqueueData(Data("before".utf8)) == .enqueued)
            inputBuffer.enqueueControl(.snapshotBoundary(viewerId: "viewer-b"))
            #expect(inputBuffer.enqueueData(Data("after".utf8)) == .enqueued)

            while let input = inputBuffer.dequeue() {
                switch input {
                case let .data(data):
                    context.appendIncomingData(data)
                case let .snapshotBoundary(viewerId, _):
                    context.discardBootstrapData(for: viewerId)
                case .finishBootstrap,
                     .reset,
                     .resyncFailed:
                    Issue.record("Unexpected control event")
                }
            }

            #expect(context.flushPendingData().data == Data("beforeafter".utf8))
            #expect(context.takeBootstrapData(for: "viewer-b") == Data("after".utf8))
        }

        @Test("Removing a viewer excludes it from future batches")
        func removedViewerIsNotARouteRecipient() {
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.beginBootstrap(for: "viewer-b")
            context.finishBootstrap(for: "viewer-b")
            context.removeViewer("viewer-a")

            context.appendIncomingData(Data("x".utf8))

            #expect(context.flushPendingData().recipients == ["viewer-b"])
        }

        @Test("Bootstrap barrier handles completion before waiter registration")
        func earlyBootstrapBarrierCompletion() async {
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            let barrierId = UUID()

            context.completeBootstrapBarrier(barrierId)
            await context.waitForBootstrapBarrier(barrierId)
        }

        @Test("Bootstrap sends established and joining viewers exactly once")
        func bootstrapRoutesWithoutCrossViewerRefresh() async {
            let sender = CapturingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.beginBootstrap(for: "viewer-b")
            context.appendIncomingData(Data("abc".utf8))

            await service.completeBootstrap(
                for: "viewer-b",
                barrierId: UUID(),
                context: context,
                paneId: "%1"
            )

            #expect(sender.dataDeliveries.count == 2)
            #expect(sender.dataDeliveries[0].data == Data("abc".utf8))
            #expect(sender.dataDeliveries[0].recipients == ["viewer-a"])
            #expect(sender.dataDeliveries[1].data == Data("abc".utf8))
            #expect(sender.dataDeliveries[1].recipients == ["viewer-b"])
            #expect(context.readyViewers == ["viewer-a", "viewer-b"])
        }

        @Test("Bootstrap output is split into bounded relay messages")
        func bootstrapUsesBoundedChunks() async {
            let sender = CapturingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.appendIncomingData(Data(repeating: 0x61, count: 20_000))

            await service.completeBootstrap(
                for: "viewer-a",
                barrierId: UUID(),
                context: context,
                paneId: "%1"
            )

            #expect(sender.dataDeliveries.map(\.data.count) == [8_192, 8_192, 3_616])
            #expect(sender.dataDeliveries.allSatisfy { $0.recipients == ["viewer-a"] })
            #expect(context.isReady("viewer-a"))
        }

        @Test("Initial snapshot metadata precedes bounded content chunks")
        func initialSnapshotUsesBoundedChunks() async {
            let sender = CapturingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let snapshot = Data(repeating: 0x61, count: 150_000)

            await service.sendSnapshot(
                kind: .initial,
                paneId: "%1",
                width: 80,
                height: 24,
                content: snapshot,
                scrollbackLineLimit: 10_000,
                recipients: ["viewer-a"]
            )

            #expect(sender.initialDeliveries.count == 1)
            #expect(sender.initialDeliveries[0].state.content == Data())
            #expect(sender.initialDeliveries[0].state.scrollbackLineLimit == 10_000)
            #expect(sender.initialDeliveries[0].state.contentByteCount == snapshot.count)
            #expect(sender.initialDeliveries[0].recipients == ["viewer-a"])
            #expect(sender.dataDeliveries.map(\.data.count) == [65_536, 65_536, 18_928])
            #expect(sender.dataDeliveries.reduce(into: Data()) { $0.append($1.data) } == snapshot)
        }

        @Test("Concurrent reset waits for the complete initial snapshot transaction")
        func concurrentSnapshotsDoNotInterleave() async {
            let sender = SuspendingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let initialContent = Data(repeating: 0x61, count: 70_000)
            let resetContent = Data("reset".utf8)

            let initialTask = Task { @MainActor in
                await service.sendSnapshot(
                    kind: .initial,
                    paneId: "%1",
                    width: 80,
                    height: 24,
                    content: initialContent,
                    scrollbackLineLimit: 10_000,
                    recipients: ["viewer-a"]
                )
            }
            await sender.waitUntilFirstDeliveryIsSuspended()

            let resetTask = Task { @MainActor in
                await service.sendSnapshot(
                    kind: .reset,
                    paneId: "%1",
                    width: 80,
                    height: 24,
                    content: resetContent,
                    scrollbackLineLimit: 10_000,
                    recipients: ["viewer-a"]
                )
            }
            for _ in 0..<10 {
                await Task.yield()
            }

            #expect(sender.deliveryKinds == ["initial"])
            sender.resumeFirstDelivery()
            _ = await initialTask.value
            _ = await resetTask.value

            #expect(sender.deliveryKinds == ["initial", "data", "data", "reset", "data"])
            #expect(sender.deliveries.allSatisfy { $0.recipients == ["viewer-a"] })
        }

        @Test("Pane discovery stops a replaced identity even when the runtime ID survives")
        func discoveryReplacesIdentity() async {
            let sender = CapturingTerminalStreamSender()
            let identity = WorkspacePaneIdentity(serverID: "1:1", sessionID: UUID(), windowID: UUID(), paneID: UUID())
            let lease = UUID()
            let context = StreamContext(paneId: "%1", viewerId: "viewer", leaseId: lease, workspaceIdentity: identity)
            let service = TerminalStreamService(streamSender: sender, activeStreams: ["%1": context])
            func pane(_ identity: WorkspacePaneIdentity) -> PaneInfo {
                .init(
                    paneId: "%1",
                    target: "s:0.0",
                    sessionName: "s",
                    windowIndex: 0,
                    tmuxWindowId: "@0",
                    paneIndex: 0,
                    command: "sh",
                    currentPath: "/tmp",
                    width: 80,
                    height: 24,
                    isActive: true,
                    workspaceIdentity: identity
                )
            }
            var moved = identity
            moved.sessionID = UUID()
            moved.windowID = UUID()
            await service.stopStreamsForClosedPanes(currentPanes: [pane(moved)])
            #expect(service.isStreaming(paneId: "%1"))
            var restarted = moved
            restarted.serverID = "2:2"
            await service.stopStreamsForClosedPanes(currentPanes: [pane(restarted)])
            #expect(!service.isStreaming(paneId: "%1"))
            #expect(sender.deliveries.count == 1)
            #expect(sender.deliveries.first?.message.updateType == .streamEnd)
            #expect(sender.deliveries.first?.leaseIDs == ["viewer": lease])
        }

        @Test("A snapshot keeps its original lease across a replacement subscription")
        func snapshotKeepsAdmittedLease() async {
            let sender = SuspendingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let original = UUID()
            let replacement = UUID()
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a", leaseId: original)
            context.beginBootstrap(for: "viewer-b", leaseId: UUID())
            let leases = context.ownership.leaseIDs
            let task = Task {
                await service.sendSnapshot(
                    kind: .initial, paneId: "%1", width: 80, height: 24,
                    content: Data(repeating: 0x61, count: 150_000), scrollbackLineLimit: 100,
                    recipients: context.ownership.subscribers, leaseIDs: context.ownership.leaseIDs
                )
            }
            await sender.waitUntilFirstDeliveryIsSuspended()
            context.beginBootstrap(for: "viewer-a", leaseId: replacement)
            sender.resumeFirstDelivery()
            await task.value
            #expect(sender.deliveries.count == 4)
            #expect(sender.deliveries.allSatisfy { $0.leaseIDs == leases })
        }

        @Test("A late bootstrap completion cannot make the replacement lease ready")
        func staleBootstrapDoesNotCompleteReplacement() async {
            let sender = SuspendingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let original = UUID()
            let replacement = UUID()
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a", leaseId: original)
            context.appendIncomingData(Data("original".utf8))
            let task = Task {
                await service.completeBootstrap(for: "viewer-a", barrierId: UUID(), context: context, paneId: "%1", leaseId: original)
            }
            await sender.waitUntilFirstDeliveryIsSuspended()
            context.beginBootstrap(for: "viewer-a", leaseId: replacement)
            context.appendIncomingData(Data("new".utf8))
            sender.resumeFirstDelivery()
            await task.value
            #expect(!context.isReady("viewer-a"))
            #expect(context.isBootstrapping("viewer-a"))
            #expect(sender.deliveries.allSatisfy { $0.leaseIDs == ["viewer-a": original] })
            await service.completeBootstrap(for: "viewer-a", barrierId: UUID(), context: context, paneId: "%1", leaseId: replacement)
            #expect(context.isReady("viewer-a"))
            #expect(sender.deliveries.last?.leaseIDs == ["viewer-a": replacement])
            #expect(sender.deliveries.last?.message.updateType == .dataChunk(.init(data: Data("new".utf8))))
        }

        @Test("Oversized live output is split into bounded relay messages")
        func liveOutputUsesBoundedChunks() async {
            let sender = CapturingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")

            await service.handleIncomingData(
                context: context,
                paneId: "%1",
                data: Data(repeating: 0x61, count: 65_536)
            )

            #expect(sender.dataDeliveries.map(\.data.count) == Array(repeating: 8_192, count: 8))
            #expect(sender.dataDeliveries.allSatisfy { $0.recipients == ["viewer-a"] })
            #expect(context.pendingDataSize == 0)
        }

        @Test("High water preserves controls and requests one snapshot")
        func highWaterCollapsesDataIntoSnapshot() {
            let buffer = TerminalStreamInputBuffer(paneId: "%1", highWaterBytes: 5)
            let barrierId = UUID()

            #expect(buffer.enqueueData(Data("abc".utf8)) == .enqueued)
            buffer.enqueueControl(.snapshotBoundary(viewerId: "viewer-a"))
            buffer.enqueueControl(.finishBootstrap(viewerId: "viewer-a", barrierId: barrierId))
            #expect(buffer.enqueueData(Data("def".utf8)) == .resyncRequired)
            #expect(buffer.enqueueData(Data("ignored".utf8)) == .awaitingSnapshot)
            #expect(buffer.queuedBytes == 0)

            let snapshot = PaneStreamManager.SubscriptionResult(
                subscriptionId: UUID(),
                initialContent: Data("snapshot".utf8),
                width: 80,
                height: 24
            )
            buffer.enqueueReset(snapshot)

            guard case let .reset(received)? = buffer.dequeue() else {
                Issue.record("Expected reset before preserved control barrier")
                return
            }
            #expect(received.initialContent == Data("snapshot".utf8))
            guard case let .snapshotBoundary(boundaryViewerId, _)? = buffer.dequeue() else {
                Issue.record("Expected preserved snapshot boundary")
                return
            }
            #expect(boundaryViewerId == "viewer-a")
            guard case let .finishBootstrap(viewerId, receivedBarrier, _)? = buffer.dequeue() else {
                Issue.record("Expected preserved bootstrap barrier")
                return
            }
            #expect(viewerId == "viewer-a")
            #expect(receivedBarrier == barrierId)
            #expect(buffer.dequeue() == nil)
        }

        @Test("Snapshot reset precedes fresh data and clears stale viewer buffers")
        func snapshotResetOrdering() async {
            let sender = CapturingTerminalStreamSender()
            let service = TerminalStreamService(streamSender: sender)
            let context = StreamContext(paneId: "%1", viewerId: "viewer-a")
            context.finishBootstrap(for: "viewer-a")
            context.beginBootstrap(for: "viewer-b")
            context.appendIncomingData(Data("stale".utf8))

            let snapshot = PaneStreamManager.SubscriptionResult(
                subscriptionId: UUID(),
                initialContent: Data("snapshot".utf8),
                width: 80,
                height: 24
            )
            await service.applyReset(snapshot, context: context, paneId: "%1")

            let fresh = Data(repeating: 0x61, count: 8_192)
            await service.handleIncomingData(context: context, paneId: "%1", data: fresh)

            #expect(sender.deliveries.count == 3)
            #expect(sender.resetDeliveries.count == 1)
            #expect(sender.resetDeliveries[0].state.content == Data())
            #expect(sender.resetDeliveries[0].state.scrollbackLineLimit == 10_000)
            #expect(sender.resetDeliveries[0].state.contentByteCount == Data("snapshot".utf8).count)
            #expect(sender.resetDeliveries[0].recipients == ["viewer-a", "viewer-b"])
            #expect(sender.dataDeliveries.count == 2)
            #expect(sender.dataDeliveries[0].data == Data("snapshot".utf8))
            #expect(sender.dataDeliveries[0].recipients == ["viewer-a", "viewer-b"])
            #expect(sender.dataDeliveries[1].data == fresh)
            #expect(sender.dataDeliveries[1].recipients == ["viewer-a"])
            #expect(context.takeBootstrapData(for: "viewer-b") == fresh)
        }

        @Test("Only slow bootstraps cross the warning threshold")
        func bootstrapTraceThreshold() {
            let fast = TerminalBootstrapTrace(
                paneId: "%1",
                viewerId: "viewer-a",
                captureMilliseconds: 120,
                initialPayloadBytes: 42_000,
                queueDepth: 0,
                oldestQueueWaitMilliseconds: 0,
                initialSendMilliseconds: 80,
                totalMilliseconds: 240
            )
            let slow = TerminalBootstrapTrace(
                paneId: "%1",
                viewerId: "viewer-a",
                captureMilliseconds: 120,
                initialPayloadBytes: 42_000,
                queueDepth: 3,
                oldestQueueWaitMilliseconds: 900,
                initialSendMilliseconds: 1_100,
                totalMilliseconds: 1_350
            )

            #expect(!fast.isSlow)
            #expect(slow.isSlow)
        }
    }
#endif
