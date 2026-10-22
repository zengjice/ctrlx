#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation
    import Logging
    import os.lock

    enum PipePaneReaderTermination: Equatable, Sendable, CustomStringConvertible {
        case endOfFile
        case readError(Int32)

        var description: String {
            switch self {
            case .endOfFile:
                "EOF"
            case let .readError(errorCode):
                "read error \(errorCode): \(String(cString: strerror(errorCode)))"
            }
        }
    }

    enum PipePaneReadDisposition: Equatable, Sendable {
        case data
        case retry
        case terminate(PipePaneReaderTermination)

        static func classify(bytesRead: Int, errorCode: Int32) -> Self {
            if bytesRead > 0 { return .data }
            if bytesRead == 0 { return .terminate(.endOfFile) }
            if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == EINTR {
                return .retry
            }
            return .terminate(.readError(errorCode))
        }
    }

    /// Receives events parsed by `PipePaneReader`.
    ///
    /// All methods are called on the main actor. The reader coalesces pending
    /// events into one MainActor delivery loop.
    @MainActor
    protocol PipePaneReaderDelegate: AnyObject, Sendable {
        func pipePaneReader(
            _ reader: PipePaneReader,
            paneId: String,
            didReceiveNotification notification: TerminalStreamMessage.TerminalNotification
        )
        func pipePaneReader(_ reader: PipePaneReader, paneId: String, didReceiveTitle title: String)
        func pipePaneReader(_ reader: PipePaneReader, paneId: String, didReceiveClipboard content: String)
        func pipePaneReader(_ reader: PipePaneReader, paneId: String, didReceiveProgress progress: TerminalProgressState)
        func pipePaneReader(
            _ reader: PipePaneReader,
            paneId: String,
            didTerminate reason: PipePaneReaderTermination
        )
    }

    /// Scans one pane's raw FIFO output for OSC side effects.
    ///
    /// A single `PipePaneReader` lives for the full lifetime of its tmux pane.
    /// It never delivers terminal bytes: the ordered control connection owns
    /// snapshots and live output. This independent scan-only path exists solely
    /// for notifications, titles, clipboard updates, and progress events.
    ///
    /// FIFO connection sequence:
    /// 1. Create FIFO with `mkfifo()`
    /// 2. Send `pipe-pane` command through control mode (returns immediately)
    /// 3. tmux starts `cat > fifo` subprocess (blocks on open until reader connects)
    /// 4. Open FIFO for reading (unblocks writer, data flows)
    actor PipePaneReader {
        /// `paneId` never changes after init; expose nonisolated so the delegate
        /// (which receives the id with every callback) doesn't need to cross
        /// actor boundaries to read it.
        nonisolated let paneId: String
        private let logger: Logging.Logger

        // FIFO state
        private let fifoPath: String
        private var fileHandle: FileHandle?
        private var isRunning = false
        private var isStopping = false
        private var terminationReported = false
        private var streamGeneration: UUID?
        private var attachedServerID: String?

        // Delivery
        private weak var delegate: (any PipePaneReaderDelegate)?
        private var pendingDelegateEvents: [DelegateEvent] = []
        private var pendingDelegateHeadIndex = 0
        private var delegateDeliveryScheduled = false

        // AsyncStream for FIFO-ordered data processing.
        // readabilityHandler yields into this stream; a single consumer task
        // processes chunks in order, preventing the reordering that occurs
        // with unstructured Task {} per callback.
        private var dataContinuation: AsyncStream<Void>.Continuation?
        private var consumerTask: Task<Void, Never>?
        private let ingressBuffer: PipeIngressBuffer

        /// Eight maximum-size FIFO reads keep at most 512 KiB before the parser.
        /// An overflow resets the scan parser; terminal delivery is unaffected.
        private static let ingressBufferChunks = 8
        private static let maximumDelegateEventsPerTurn = 32
        private static let maximumDelegateBytesPerTurn = 256 * 1_024

        /// Parser for OSC events. `scanOnly` avoids rebuilding terminal data.
        private var notificationParser = TerminalNotificationParser(scanOnly: true)

        init(paneId: String, fifoDirectory: URL = FileManager.default.temporaryDirectory) {
            self.paneId = paneId
            self.logger = Logging.Logger(label: "com.jicezeng.ctrlx.pipepane.\(paneId)")
            self.ingressBuffer = PipeIngressBuffer(
                paneId: paneId,
                maximumChunks: Self.ingressBufferChunks
            )

            // Sanitize pane ID for filesystem: "%5" -> "5"
            let sanitized = paneId.replacingOccurrences(of: "%", with: "")
            precondition(
                !sanitized.isEmpty && sanitized.allSatisfy(\.isNumber),
                "Pane ID must contain only digits after stripping '%', got: \(paneId)"
            )
            self.fifoPath = fifoDirectory.appendingPathComponent("ctrlx-pipe-\(sanitized)-\(UUID().uuidString).fifo").path
        }

        // MARK: - Public API

        /// Sets the delegate that receives parsed events. Stored weakly; the
        /// delegate must outlive the reader.
        func setDelegate(_ delegate: (any PipePaneReaderDelegate)?) {
            self.delegate = delegate
        }

        /// Starts pipe-pane for this pane, creating the FIFO and opening it for reading.
        ///
        /// Terminal bytes are always discarded after OSC side effects are parsed.
        ///
        /// - Parameter controlClientManager: Used to send the pipe-pane command
        /// - Parameter sessionName: The tmux session name for the control client
        func startPipePane(
            controlClientManager: TmuxControlClientManager,
            sessionName: String,
            expectedServerID: String? = nil
        ) async throws {
            guard !isRunning else {
                logger.warning("pipe-pane already running for \(paneId)")
                return
            }

            let serverID = try await controlClientManager.serverIdentity(for: sessionName)
            guard expectedServerID == nil || expectedServerID == serverID else {
                throw TmuxControlError.commandFailed(message: "The tmux server changed before reader startup.")
            }
            attachedServerID = serverID
            defer {
                if !isRunning {
                    cleanupFifo()
                }
            }
            isStopping = false
            terminationReported = false
            notificationParser.scanOnly = true

            // Clean up any stale FIFO from a previous crash
            cleanupFifo()

            // Step 1: Create FIFO (retry once if stale file persists after cleanup)
            var result = mkfifo(fifoPath, 0o600)
            if result != 0, errno == EEXIST {
                logger.warning("FIFO still exists after cleanup, force-removing: \(fifoPath)")
                try? FileManager.default.removeItem(atPath: fifoPath)
                result = mkfifo(fifoPath, 0o600)
            }
            guard result == 0 else {
                let errorMessage = String(cString: strerror(errno))
                throw PipePaneError.fifoCreationFailed(path: fifoPath, message: errorMessage)
            }

            logger.debug("Created FIFO at \(fifoPath)")

            // Step 2: Stop any existing pipe-pane for this pane, then start new one
            _ = try? await controlClientManager.sendCommand(
                "pipe-pane -t '\(paneId)'",
                sessionName: sessionName,
                expectedServerID: serverID
            )
            _ = try await controlClientManager.sendCommand(
                "pipe-pane -O -t '\(paneId)' 'exec cat > \"\(fifoPath)\"'",
                sessionName: sessionName,
                expectedServerID: serverID
            )

            logger.debug("pipe-pane command sent for \(paneId)")

            // Step 3: Open FIFO for reading (this unblocks the cat writer)
            // Must be done on a background thread since open() blocks until writer connects
            let path = fifoPath
            let handle = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FileHandle, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let fd = open(path, O_RDONLY | O_NONBLOCK)
                    if fd < 0 {
                        let errorMessage = String(cString: strerror(errno))
                        continuation.resume(throwing: PipePaneError.fifoOpenFailed(
                            path: path, message: errorMessage
                        ))
                    } else {
                        continuation.resume(returning: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
                    }
                }
            }

            fileHandle = handle
            isRunning = true
            let generation = UUID()
            streamGeneration = generation

            // Step 4: Set up AsyncStream for FIFO-ordered data delivery.
            // readabilityHandler fires on a dispatch queue — yielding into the stream
            // is synchronous and non-blocking. A single consumer task drains the stream
            // in order, guaranteeing no data reordering.
            let (stream, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            dataContinuation = continuation

            // Note: readabilityHandler captures `continuation` strongly, so the handler
            // keeps yielding if PipePaneReader is deallocated without stopPipePane().
            // Callers MUST call stopPipePane() to clean up — see PaneStreamManager.
            let fd = handle.fileDescriptor
            handle.readabilityHandler = { [weak self] _ in
                // Read directly from the file descriptor to avoid NSFileHandle's
                // -availableData which throws an uncatchable NSException if the
                // descriptor was closed between the dispatch source firing and
                // the handler executing.
                var buf = [UInt8](repeating: 0, count: 65_536)
                let bytesRead = read(fd, &buf, buf.count)
                let errorCode = bytesRead < 0 ? errno : 0
                switch PipePaneReadDisposition.classify(
                    bytesRead: bytesRead,
                    errorCode: errorCode
                ) {
                case .data:
                    let data = Data(buf[..<bytesRead])
                    self?.ingressBuffer.enqueue(data)
                    continuation.yield()

                case .retry:
                    // A non-blocking descriptor can transiently report no data
                    // after the dispatch source fires. Keep the stream alive;
                    // the source will invoke us again when bytes are readable.
                    return

                case let .terminate(reason):
                    continuation.finish()
                    Task { [weak self] in
                        await self?.handleTermination(reason, generation: generation)
                    }
                }
            }

            // Single consumer task — processes data in strict FIFO order
            consumerTask = Task { [weak self] in
                for await _ in stream {
                    guard let self else { break }
                    await self.drainIngressBuffer()
                }
            }

            logger.info("pipe-pane started for \(paneId)")
        }

        /// Stops pipe-pane and cleans up all resources.
        ///
        /// - Parameter controlClientManager: Used to send the stop pipe-pane command
        /// - Parameter sessionName: The tmux session name
        func stopPipePane(
            controlClientManager: TmuxControlClientManager,
            sessionName: String
        ) async {
            guard isRunning else { return }

            logger.debug("Stopping pipe-pane for \(paneId)")
            isStopping = true
            streamGeneration = nil

            // Stop the readability handler and stream first
            fileHandle?.readabilityHandler = nil
            dataContinuation?.finish()
            dataContinuation = nil
            let task = consumerTask
            task?.cancel()
            consumerTask = nil
            _ = await task?.value
            try? fileHandle?.close()
            fileHandle = nil

            // Stop pipe-pane in tmux (this terminates the cat process)
            _ = try? await controlClientManager.sendCommand(
                "pipe-pane -t '\(paneId)'",
                sessionName: sessionName,
                expectedServerID: attachedServerID
            )

            // Clean up FIFO
            cleanupFifo()

            isRunning = false
            isStopping = false
            terminationReported = false
            discardPendingDelegateEvents()
            ingressBuffer.removeAll()
            notificationParser.reset()
            notificationParser.scanOnly = true
            logger.info("pipe-pane stopped for \(paneId)")
        }

        /// A stopped dispatch handler may still enqueue a late callback. The
        /// generation check in `handleTermination` rejects that callback after
        /// this reader has been restarted for the same pane.
        var isHealthy: Bool {
            isRunning && !isStopping && !terminationReported
        }

        // MARK: - Data Processing

        private func processIncomingData(_ data: Data) {
            guard !data.isEmpty else { return }

            // Most output has no OSC introducer. A buffered sequence disables
            // this fast path because this chunk may contain only its remainder.
            guard notificationParser.hasBufferedSequence
                || data.contains(0x1B)
                || data.contains(0x9D)
            else { return }

            let parseResult = notificationParser.parse(data)

            let notifications = parseResult.notifications
            let title = parseResult.titleChange.map(TerminalTitleStabilizer.stabilize)
            let clipboard = parseResult.clipboardContent
            let progress = parseResult.progressUpdate

            guard
                !notifications.isEmpty
                || title != nil
                || clipboard != nil
                || progress != nil
            else { return }

            var events = notifications.map(DelegateEvent.notification)
            if let title { events.append(.title(title)) }
            if let clipboard { events.append(.clipboard(clipboard)) }
            if let progress { events.append(.progress(progress)) }
            enqueueDelegateEvents(events)
        }

        /// Adds events to the FIFO delivery queue. One MainActor task drains
        /// every event currently available instead of spawning a task for
        /// every pipe read.
        private func enqueueDelegateEvents(_ events: [DelegateEvent]) {
            guard !events.isEmpty else { return }
            pendingDelegateEvents.append(contentsOf: events)
            recordDelegateQueue()
            guard !delegateDeliveryScheduled else { return }

            delegateDeliveryScheduled = true
            Task { @MainActor [weak self] in
                while let delivery = await self?.takePendingDelegateDelivery() {
                    delivery.deliver()
                    await Task.yield()
                }
            }
        }

        private func takePendingDelegateDelivery() -> DelegateDelivery? {
            guard !pendingDelegateEvents.isEmpty else {
                delegateDeliveryScheduled = false
                return nil
            }

            let availableCount = pendingDelegateEvents.count - pendingDelegateHeadIndex
            let eventCount = min(availableCount, Self.maximumDelegateEventsPerTurn)

            let endIndex = pendingDelegateHeadIndex + eventCount
            let events = Array(pendingDelegateEvents[pendingDelegateHeadIndex..<endIndex])
            pendingDelegateHeadIndex = endIndex
            compactPendingDelegateEvents()
            recordDelegateQueue()
            return DelegateDelivery(
                reader: self,
                paneId: paneId,
                delegate: WeakDelegate(delegate),
                events: events
            )
        }

        private enum DelegateEvent: Sendable {
            case notification(TerminalStreamMessage.TerminalNotification)
            case title(String)
            case clipboard(String)
            case progress(TerminalProgressState)
        }

        private struct DelegateDelivery: Sendable {
            let reader: PipePaneReader
            let paneId: String
            let delegate: WeakDelegate
            let events: [DelegateEvent]

            @MainActor
            func deliver() {
                for event in events {
                    switch event {
                    case let .notification(notification):
                        delegate.value?.pipePaneReader(reader, paneId: paneId, didReceiveNotification: notification)
                    case let .title(title):
                        delegate.value?.pipePaneReader(reader, paneId: paneId, didReceiveTitle: title)
                    case let .clipboard(clipboard):
                        delegate.value?.pipePaneReader(reader, paneId: paneId, didReceiveClipboard: clipboard)
                    case let .progress(progress):
                        delegate.value?.pipePaneReader(reader, paneId: paneId, didReceiveProgress: progress)
                    }
                }
            }
        }

        private func handleIngressOverflow() {
            notificationParser.reset()
            notificationParser.scanOnly = true
        }

        private func drainIngressBuffer() async {
            var processedChunks = 0
            var processedBytes = 0
            while !Task.isCancelled,
                  processedChunks < Self.maximumDelegateEventsPerTurn,
                  processedBytes < Self.maximumDelegateBytesPerTurn,
                  let item = ingressBuffer.dequeue() {
                if item.requiresResyncBefore {
                    handleIngressOverflow()
                }
                processIncomingData(item.data)
                processedChunks += 1
                processedBytes += item.data.count
            }

            if ingressBuffer.hasPendingData {
                dataContinuation?.yield()
                await Task.yield()
            }
        }

        private func recordDelegateQueue() {
            TerminalTransportMetrics.shared.recordQueue(
                .pipeIngress,
                id: "\(paneId):delegate",
                depth: pendingDelegateEvents.count - pendingDelegateHeadIndex,
                bytes: 0
            )
        }

        private func compactPendingDelegateEvents() {
            if pendingDelegateHeadIndex == pendingDelegateEvents.count {
                pendingDelegateEvents.removeAll(keepingCapacity: true)
                pendingDelegateHeadIndex = 0
            } else if pendingDelegateHeadIndex >= 64,
                      pendingDelegateHeadIndex * 2 >= pendingDelegateEvents.count {
                pendingDelegateEvents.removeFirst(pendingDelegateHeadIndex)
                pendingDelegateHeadIndex = 0
            }
        }

        private func discardPendingDelegateEvents() {
            pendingDelegateEvents.removeAll(keepingCapacity: false)
            pendingDelegateHeadIndex = 0
            recordDelegateQueue()
        }

        /// Tiny weak holder so we can capture the delegate reference into a
        /// `Sendable` closure without retaining it.
        private struct WeakDelegate: @unchecked Sendable {
            weak var value: (any PipePaneReaderDelegate)?
            init(_ value: (any PipePaneReaderDelegate)?) {
                self.value = value
            }
        }

        // MARK: - Test Helpers

        /// Exposes processIncomingData for testing. The data path itself is
        /// synchronous, but delegate delivery is fire-and-forget on MainActor;
        /// tests must call `testWaitForDelivery()` before asserting on the
        /// delegate so any dispatched Tasks have run.
        func testProcessIncomingData(_ data: Data) {
            processIncomingData(data)
        }

        /// Drains any MainActor delivery work dispatched by prior
        /// `testProcessIncomingData` calls. Tests assert on
        /// delegate state only after this returns.
        func testWaitForDelivery() async {
            while delegateDeliveryScheduled {
                await Task.yield()
            }
        }

        /// Exposes fifoPath for testing.
        var testFifoPath: String {
            fifoPath
        }

        // MARK: - Lifecycle

        private func handleTermination(
            _ reason: PipePaneReaderTermination,
            generation: UUID
        ) async {
            guard
                isRunning,
                !isStopping,
                !terminationReported,
                streamGeneration == generation
            else { return }

            terminationReported = true
            logger.warning("pipe-pane FIFO terminated for \(paneId): \(reason)")
            fileHandle?.readabilityHandler = nil
            dataContinuation?.finish()
            await delegate?.pipePaneReader(self, paneId: paneId, didTerminate: reason)
        }

        private func cleanupFifo() {
            unlink(fifoPath)
        }
    }

    /// Small thread-safe handoff between FileHandle's dispatch callback and the
    /// reader actor. On overflow it discards the stale queue and marks the first
    /// retained chunk as a resync boundary. A global overflow flag is racy here:
    /// the producer can overflow again while the actor is processing an older
    /// dequeued chunk, causing the reset to be applied at the wrong byte.
    final class PipeIngressBuffer: Sendable {
        struct Item: Sendable {
            let data: Data
            let requiresResyncBefore: Bool
        }

        private struct State: Sendable {
            var items: [Item] = []
            var bytes = 0
        }

        private let paneId: String
        private let maximumChunks: Int
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(paneId: String, maximumChunks: Int) {
            precondition(maximumChunks > 0)
            self.paneId = paneId
            self.maximumChunks = maximumChunks
        }

        func enqueue(_ data: Data) {
            guard !data.isEmpty else { return }
            let sample = state.withLock { state in
                let overflowed = state.items.count >= maximumChunks
                if overflowed {
                    state.items.removeAll(keepingCapacity: true)
                    state.bytes = 0
                }
                state.items.append(Item(data: data, requiresResyncBefore: overflowed))
                state.bytes += data.count
                return (state.items.count, state.bytes)
            }
            record(depth: sample.0, bytes: sample.1)
        }

        func dequeue() -> Item? {
            let sample: (item: Item?, depth: Int, bytes: Int) = state.withLock { state in
                guard !state.items.isEmpty else { return (nil, 0, 0) }
                let item = state.items.removeFirst()
                state.bytes -= item.data.count
                return (item, state.items.count, state.bytes)
            }
            record(depth: sample.depth, bytes: sample.bytes)
            return sample.item
        }

        var hasPendingData: Bool {
            state.withLock { !$0.items.isEmpty }
        }

        func removeAll() {
            state.withLock { state in
                state.items.removeAll(keepingCapacity: false)
                state.bytes = 0
            }
            record(depth: 0, bytes: 0)
        }

        private func record(depth: Int, bytes: Int) {
            TerminalTransportMetrics.shared.recordQueue(
                .pipeIngress,
                id: "\(paneId):fifo",
                depth: depth,
                bytes: bytes
            )
        }
    }

    // MARK: - Errors

    enum PipePaneError: Error, LocalizedError {
        case fifoCreationFailed(path: String, message: String)
        case fifoOpenFailed(path: String, message: String)

        var errorDescription: String? {
            switch self {
            case let .fifoCreationFailed(path, message):
                return "Failed to create FIFO at \(path): \(message)"
            case let .fifoOpenFailed(path, message):
                return "Failed to open FIFO at \(path): \(message)"
            }
        }
    }
#endif
