#if os(macOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Foundation
    import Logging

    /// Orders a new subscriber's bootstrap as one terminal byte stream:
    /// authoritative snapshot first, then every increment observed while that
    /// snapshot was being captured. Nothing reaches `onData` until `finish`
    /// makes the subscription live.
    struct PaneSubscriptionBootstrap {
        private enum State: Equatable {
            case beforeSnapshotBoundary
            case afterSnapshotBoundary
            case live
        }

        private var bufferedData = Data()
        private var state = State.beforeSnapshotBoundary

        var isCollecting: Bool {
            state != .live
        }

        var hasSnapshotBoundary: Bool {
            state == .afterSnapshotBoundary
        }

        /// Returns data only after the bootstrap has finished. While collecting,
        /// the bytes are retained for the initial payload instead.
        mutating func route(_ data: Data) -> Data? {
            guard !data.isEmpty else { return nil }
            guard state == .live else {
                bufferedData.append(data)
                return nil
            }
            return data
        }

        /// Drops bytes emitted before the capture completed. They are already
        /// represented by the authoritative snapshot and must never be replayed.
        mutating func markSnapshotBoundary() {
            guard state == .beforeSnapshotBoundary else { return }
            bufferedData.removeAll(keepingCapacity: true)
            state = .afterSnapshotBoundary
        }

        /// Completes the bootstrap as snapshot followed only by bytes emitted
        /// after the ordered control-mode boundary.
        mutating func finish(with snapshot: Data) -> Data {
            precondition(state == .afterSnapshotBoundary)
            var result = snapshot
            result.append(bufferedData)
            bufferedData.removeAll(keepingCapacity: false)
            state = .live
            return result
        }
    }

    /// Describes the single authoritative snapshot boundary created by a real
    /// pane-size change. Keeping this decision beside the shared reader makes
    /// every consumer (local Mac mirrors and relay viewers) cross the same
    /// boundary instead of repairing its own SwiftTerm instance independently.
    struct PaneDimensionResyncBoundary: Equatable {
        let width: Int
        let height: Int
        let subscriptionIds: Set<UUID>

        init?(
            currentWidth: Int,
            currentHeight: Int,
            newWidth: Int,
            newHeight: Int,
            subscriptionIds: Set<UUID>
        ) {
            guard currentWidth != newWidth || currentHeight != newHeight else { return nil }
            self.width = newWidth
            self.height = newHeight
            self.subscriptionIds = subscriptionIds
        }
    }

    /// Pending pane-wide snapshot requests. `take` removes the current round
    /// before capture starts, so an identical subscriber requesting another
    /// resync during that capture is retained for the next round.
    struct PaneResyncRequestQueue {
        private var subscriptionIdsByPane: [String: Set<UUID>] = [:]

        mutating func request(paneId: String, subscriptionIds: Set<UUID>) {
            guard !subscriptionIds.isEmpty else { return }
            subscriptionIdsByPane[paneId, default: []].formUnion(subscriptionIds)
        }

        mutating func remove(subscriptionId: UUID, paneId: String) {
            subscriptionIdsByPane[paneId]?.remove(subscriptionId)
            if subscriptionIdsByPane[paneId]?.isEmpty == true {
                subscriptionIdsByPane.removeValue(forKey: paneId)
            }
        }

        mutating func take(paneId: String) -> Set<UUID> {
            subscriptionIdsByPane.removeValue(forKey: paneId) ?? []
        }

        func hasRequests(paneId: String) -> Bool {
            subscriptionIdsByPane[paneId]?.isEmpty == false
        }

        mutating func discard(paneId: String) {
            subscriptionIdsByPane.removeValue(forKey: paneId)
        }

        mutating func removeAll() {
            subscriptionIdsByPane.removeAll()
        }
    }

    /// Coalesces concurrent attempts to start the same pane reader.
    ///
    /// Pane discovery and a newly-created terminal view can observe an unknown
    /// pane at the same time. Starting two readers would make both instances
    /// replace the same tmux `pipe-pane` and FIFO, leaving one retained reader
    /// permanently disconnected. MainActor isolation makes a task table enough;
    /// no lock or second actor is needed.
    @MainActor
    final class PaneReaderStartGate {
        private struct Flight {
            let token: UUID
            let task: Task<Bool, Never>
        }

        private var flights: [String: Flight] = [:]

        func run(
            paneId: String,
            operation: @escaping @MainActor () async -> Bool
        ) async -> Bool {
            if let flight = flights[paneId] {
                return await flight.task.value
            }

            let token = UUID()
            let task = Task { await operation() }
            flights[paneId] = Flight(token: token, task: task)

            let result = await task.value
            if flights[paneId]?.token == token {
                flights.removeValue(forKey: paneId)
            }
            return result
        }

        func cancelAll() async {
            let active = Array(flights.values)
            flights.removeAll()
            for flight in active {
                flight.task.cancel()
            }
            for flight in active {
                _ = await flight.task.value
            }
        }
    }

    /// Owns pane snapshots/live output plus one scan-only OSC reader per pane.
    ///
    /// Terminal content has exactly one source: the tmux control connection.
    /// The persistent FIFO reader never forwards terminal bytes; it only parses
    /// notifications, titles, clipboard updates, and progress events.
    ///
    /// Usage:
    /// 1. Call `subscribe(paneId:target:...)` to get a subscription ID.
    /// 2. Data and dimension changes flow to your callbacks.
    /// 3. Call `unsubscribe(_:)` when done.
    /// 4. Control output is disabled when the last subscriber leaves.
    @Observable
    @MainActor
    final public class PaneStreamManager: PipePaneReaderDelegate {
        // MARK: - Types

        /// A subscription to a pane stream
        private struct Subscription {
            let id: UUID
            let paneId: String
            let maximumSnapshotScrollbackLineLimit: Int?
            let onData: @MainActor (Data) -> Void
            let onDimensionChange: (@MainActor (Int, Int) -> Void)?
            let onTitleChange: (@MainActor (String) -> Void)?
            let onNotification: (@MainActor (TerminalStreamMessage.TerminalNotification) -> Void)?
            let onClipboard: (@MainActor (String) -> Void)?
            let onResync: (@MainActor (Result<SubscriptionResult, Error>) -> Void)?
            var bootstrap = PaneSubscriptionBootstrap()
        }

        /// Per-pane state owned by the manager.
        ///
        /// One context exists for every known pane regardless of subscriber
        /// count. Dimensions live here so they can be queried for a pane that
        /// doesn't (yet) have a subscriber.
        private struct ReaderContext {
            let reader: PipePaneReader
            var target: String
            var sessionName: String
            var width: Int
            var height: Int
            var subscriberIds: Set<UUID>
            /// Last terminal title detected via OSC 0/2 or seeded from tmux's
            /// `pane_title`. Cleared only when the reader is torn down.
            var terminalTitle: String?
            /// Whether `controlClientManager.registerPaneDimensions` has been
            /// called for this pane. Registered on first subscriber so the
            /// dimension-change callback is wired before any subscriber needs
            /// it; unregistered when the reader is torn down.
            var hasRegisteredDimensions: Bool
        }

        // MARK: - Properties

        private let logger = Logger(label: "com.jicezeng.ctrlx.panestreammanager")
        private let tmuxService: TmuxService
        private let controlClientManager: TmuxControlClientManager
        private let scrollbackLineLimitProvider: @MainActor () -> Int
        private let fifoDirectory: URL

        private var configuredScrollbackLineLimit: Int {
            TerminalScrollbackPolicy.normalizedLineLimit(scrollbackLineLimitProvider())
        }

        private func resolvedSnapshotScrollbackLineLimit(maximum: Int?) -> Int {
            TerminalScrollbackPolicy.snapshotLineLimit(
                configuredLineLimit: configuredScrollbackLineLimit,
                maximumSnapshotLineLimit: maximum
            )
        }

        /// Active per-pane state keyed by paneId. One entry per known pane.
        private var readers: [String: ReaderContext] = [:]

        /// All subscriptions keyed by subscription ID
        private var subscriptions: [UUID: Subscription] = [:]

        /// Task for periodic pane discovery (needed to detect new tmux sessions)
        private var paneRefreshTask: Task<Void, Never>?

        /// Per-pane single-flight for reader startup. Without this, an on-demand
        /// subscribe can race pane discovery and both replace the same FIFO.
        private let readerStartGate = PaneReaderStartGate()

        /// Overload recovery is coalesced per pane. While a snapshot is being
        /// captured, incremental callbacks are suppressed and the reader buffers
        /// the post-snapshot boundary for an ordered flush.
        private var pendingResyncRequests = PaneResyncRequestQueue()
        private var resyncTasks: [String: Task<Void, Never>] = [:]
        private var resyncingPaneIds: Set<String> = []
        private var resyncBootstraps: [String: PaneSubscriptionBootstrap] = [:]

        /// A terminated FIFO is restarted in place so existing subscriptions,
        /// dimensions, and title state remain authoritative. One recovery task
        /// per pane also prevents a burst of EOF/error callbacks from launching
        /// competing `pipe-pane` commands.
        private var readerRecoveryTasks: [String: Task<Void, Never>] = [:]

        /// `disconnectAll` is terminal for this manager. Keep late callbacks
        /// from restarting readers while shutdown drains in-flight work.
        private var isShuttingDown = false

        /// Global notification handler — called for any notification on any pane,
        /// regardless of which subscribers are active. Used by macOS to show desktop notifications.
        public var onNotification: (@MainActor (String, TerminalStreamMessage.TerminalNotification) -> Void)?

        /// Global title change handler — called whenever a title is detected on
        /// any pane. Parameters: (paneId, target, title).
        public var onTitleChange: (@MainActor (String, String, String) -> Void)?

        /// Global progress handler — called for any `OSC 9;4` progress update on any pane.
        /// `.removed` means progress is cleared. Used to drive the sidebar progress bar.
        public var onProgress: (@MainActor (String, TerminalProgressState) -> Void)?

        // MARK: - Public State

        /// Pane IDs that currently have at least one active subscriber (mirror or relay viewer).
        public var activeStreamPaneIds: [String] {
            readers.compactMap { $0.value.subscriberIds.isEmpty ? nil : $0.key }
        }

        /// Whether a pane has at least one active subscriber.
        public func hasActiveStream(paneId: String) -> Bool {
            guard let context = readers[paneId] else { return false }
            return !context.subscriberIds.isEmpty
        }

        /// Get current dimensions for a pane.
        public func dimensions(for paneId: String) -> (width: Int, height: Int)? {
            guard let context = readers[paneId] else { return nil }
            return (context.width, context.height)
        }

        /// Get current terminal title for a pane (if a title has been seen).
        public func terminalTitle(for paneId: String) -> String? {
            readers[paneId]?.terminalTitle
        }

        /// Sends local interactive input through the pane's existing control client.
        /// Returns `false` when the reader or connection is not ready so the caller
        /// can safely use the process-based tmux fallback.
        func sendKeystrokesIfConnected(
            paneId: String,
            keys: [TmuxKey],
            onFirstCommandWritten: (@Sendable () -> Void)? = nil
        ) async throws -> Bool {
            guard let context = readers[paneId] else { return false }
            return try await controlClientManager.sendKeystrokesIfConnected(
                paneId: paneId,
                sessionName: context.sessionName,
                keys: keys,
                onFirstCommandWritten: onFirstCommandWritten
            )
        }

        /// Raw mouse input uses the same existing session connection as keys.
        /// Only `false` permits the caller to use the process fallback.
        func sendRawBytesIfConnected(
            paneId: String,
            data: Data,
            onFirstCommandWritten: (@Sendable () -> Void)? = nil
        ) async throws -> Bool {
            guard let context = readers[paneId] else { return false }
            return try await controlClientManager.sendRawBytesIfConnected(
                paneId: paneId,
                sessionName: context.sessionName,
                data: data,
                onFirstCommandWritten: onFirstCommandWritten
            )
        }

        /// Known default pane titles to filter out when seeding from tmux state.
        /// Tmux initializes `pane_title` to the system hostname, which may appear
        /// in various forms depending on the system configuration.
        private let defaultPaneTitles: Set<String> = {
            var defaults = Set<String>()
            // Use only `gethostname()` here — a pure syscall. Do NOT call
            // `ProcessInfo.processInfo.hostName`: it resolves the machine's `.local`
            // name, which is a local-network DNS operation (Apple TN3179). On a
            // macOS 15+ machine that hasn't decided Local Network access, that
            // resolution BLOCKS the calling thread until the decision is made — and
            // this property is evaluated synchronously on the main thread during
            // `AppCoordinator.init`, so it would hang app startup (the main-queue
            // NWListener for the E2E test server never binds). `gethostname()` is
            // what tmux uses for the default `pane_title` anyway.
            var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
            if
                gethostname(&buffer, buffer.count) == 0,
                let hostname = String(validating: buffer.prefix(while: { $0 != 0 }), as: UTF8.self) {
                defaults.insert(hostname)
                if let dotIndex = hostname.firstIndex(of: ".") {
                    defaults.insert(String(hostname[..<dotIndex]))
                }
            }
            return defaults
        }()

        // MARK: - Initialization

        public init(
            tmuxService: TmuxService,
            controlClientManager: TmuxControlClientManager,
            scrollbackLineLimitProvider: @escaping @MainActor () -> Int = {
                TerminalScrollbackPolicy.defaultLineLimit
            },
            fifoDirectory: URL = FileManager.default.temporaryDirectory
        ) {
            self.tmuxService = tmuxService
            self.controlClientManager = controlClientManager
            self.scrollbackLineLimitProvider = scrollbackLineLimitProvider
            self.fifoDirectory = fifoDirectory

            // Wire up dimension changes from control client
            controlClientManager.setOnDimensionChange { [weak self] paneId, width, height in
                self?.updateDimensions(paneId: paneId, width: width, height: height)
            }
            controlClientManager.setOnOutput { [weak self] paneId, data in
                self?.handleControlOutput(paneId: paneId, data: data)
            }
        }

        /// Whether a pane title from tmux is a custom title (not a default hostname variant).
        private func isCustomPaneTitle(_ title: String) -> Bool {
            !title.isEmpty && !defaultPaneTitles.contains(title)
        }

        // MARK: - Public API

        /// Result of subscribing to a pane stream
        public struct SubscriptionResult {
            /// Subscription ID to use when unsubscribing
            public let subscriptionId: UUID
            /// Initial terminal content (scrollback + visible area)
            public let initialContent: Data
            /// Terminal width in columns
            public let width: Int
            /// Terminal height in rows
            public let height: Int
            /// Maximum history lines the subscriber should retain while streaming.
            /// The initial snapshot may contain fewer historical lines.
            public let scrollbackLineLimit: Int

            public init(
                subscriptionId: UUID,
                initialContent: Data,
                width: Int,
                height: Int,
                scrollbackLineLimit: Int = TerminalScrollbackPolicy.defaultLineLimit
            ) {
                self.subscriptionId = subscriptionId
                self.initialContent = initialContent
                self.width = width
                self.height = height
                self.scrollbackLineLimit = TerminalScrollbackPolicy.normalizedLineLimit(scrollbackLineLimit)
            }
        }

        /// Subscribe to a pane stream.
        ///
        /// Every subscriber is registered behind a private bootstrap gate before
        /// capture begins. Its initial result is one ordered stream containing
        /// the authoritative snapshot followed by all capture-time increments;
        /// only then does its `onData` callback become live. Existing subscribers
        /// continue receiving output while a later subscriber bootstraps.
        ///
        /// - Parameters:
        ///   - paneId: The pane ID (e.g., "%1")
        ///   - target: The pane target (e.g., "mysession:0.1")
        ///   - onData: Callback for incoming terminal data (live updates only, not initial content)
        ///   - onDimensionChange: Optional callback for dimension changes
        ///   - onTitleChange: Optional callback for terminal title changes
        ///   - onNotification: Optional callback for terminal notifications (OSC 9/777)
        /// - Returns: Subscription result containing ID, initial content, and dimensions
        /// - Throws: If the stream fails to connect
        public func subscribe(
            paneId: String,
            target: String,
            maximumSnapshotScrollbackLineLimit: Int? = nil,
            onData: @escaping @MainActor (Data) -> Void,
            onDimensionChange: (@MainActor (Int, Int) -> Void)? = nil,
            onTitleChange: (@MainActor (String) -> Void)? = nil,
            onNotification: (@MainActor (TerminalStreamMessage.TerminalNotification) -> Void)? = nil,
            onClipboard: (@MainActor (String) -> Void)? = nil,
            onResync: (@MainActor (Result<SubscriptionResult, Error>) -> Void)? = nil
        ) async throws -> SubscriptionResult {
            let subscriptionId = UUID()
            let viewerScrollbackLineLimit = configuredScrollbackLineLimit
            let snapshotScrollbackLineLimit = resolvedSnapshotScrollbackLineLimit(
                maximum: maximumSnapshotScrollbackLineLimit
            )
            let subscription = Subscription(
                id: subscriptionId,
                paneId: paneId,
                maximumSnapshotScrollbackLineLimit: maximumSnapshotScrollbackLineLimit,
                onData: onData,
                onDimensionChange: onDimensionChange,
                onTitleChange: onTitleChange,
                onNotification: onNotification,
                onClipboard: onClipboard,
                onResync: onResync
            )

            // Pane discovery normally creates the reader before any subscribe is
            // possible, but a subscribe can race in (e.g. a pane created seconds
            // before the next refresh). Start a reader on demand so the first
            // viewer doesn't have to wait for the periodic refresh tick.
            if readers[paneId] == nil {
                // A stable pane target ("%7") is not a session name. Resolve it
                // once on discovery races; all later operations use the reader's
                // owning session so output and snapshots share one connection.
                let sessionName = try await tmuxService.getPaneSessionName(paneId)
                let dims = (try? await tmuxService.getPaneDimensions(paneId)) ?? (width: 80, height: 24)
                await ensureReader(
                    paneId: paneId,
                    sessionName: sessionName,
                    target: target,
                    initialWidth: dims.width,
                    initialHeight: dims.height,
                    seedTitle: nil
                )
            }

            guard var context = readers[paneId] else {
                throw TmuxError.invalidPane(target: target)
            }

            let isFirstSubscriber = context.subscriberIds.isEmpty

            // Register every subscriber before the first suspension point. Its
            // bootstrap gate buffers only that subscriber's data, while existing
            // live subscribers continue receiving output normally. This removes
            // both historical races:
            // - first subscriber: live bytes used to arrive before its snapshot;
            // - later subscriber: bytes between capture and registration vanished.
            context.subscriberIds.insert(subscriptionId)
            readers[paneId] = context
            subscriptions[subscriptionId] = subscription

            if isFirstSubscriber {
                do {
                    try await controlClientManager.setPaneOutputEnabled(
                        paneId: paneId,
                        sessionName: context.sessionName,
                        enabled: true
                    )
                } catch {
                    await rollbackBootstrap(subscriptionId: subscriptionId, paneId: paneId)
                    throw error
                }
            }

            // Refresh dimensions for every bootstrap. A pane may have changed
            // since discovery even when another subscriber is already live.
            if let dims = try? await tmuxService.getPaneDimensions(target),
               var refreshed = readers[paneId],
               refreshed.reader === context.reader {
                refreshed.width = dims.width
                refreshed.height = dims.height
                readers[paneId] = refreshed
            }

            guard var captureContext = readers[paneId],
                  captureContext.reader === context.reader,
                  captureContext.subscriberIds.contains(subscriptionId) else {
                await rollbackBootstrap(
                    subscriptionId: subscriptionId,
                    paneId: paneId
                )
                throw TmuxError.invalidPane(target: target)
            }

            // Register dimension tracking once per reader so later layout
            // changes flow into the shared context.
            if !captureContext.hasRegisteredDimensions {
                do {
                    try await controlClientManager.registerPaneDimensions(
                        paneId: paneId,
                        sessionName: captureContext.sessionName,
                        dimensions: (width: captureContext.width, height: captureContext.height)
                    )
                    if var refreshed = readers[paneId], refreshed.reader === context.reader {
                        refreshed.hasRegisteredDimensions = true
                        readers[paneId] = refreshed
                        captureContext = refreshed
                    }
                } catch {
                    logger.warning("Failed to register pane dimensions", metadata: [
                        "paneId": "\(paneId)",
                        "error": "\(error)",
                    ])
                }
            }

            let snapshot: Data
            do {
                snapshot = try await tmuxService.capturePaneViaControlMode(
                    paneId: paneId,
                    width: captureContext.width,
                    height: captureContext.height,
                    controlClientManager: controlClientManager,
                    sessionName: captureContext.sessionName,
                    scrollbackLineLimit: snapshotScrollbackLineLimit,
                    onSnapshotBoundary: { [weak self] in
                        guard var pending = self?.subscriptions[subscriptionId] else { return }
                        pending.bootstrap.markSnapshotBoundary()
                        self?.subscriptions[subscriptionId] = pending
                    }
                )
            } catch {
                await rollbackBootstrap(
                    subscriptionId: subscriptionId,
                    paneId: paneId
                )
                throw error
            }

            // No await after this transition: MainActor cannot deliver another
            // pipe event between making the subscription live and returning its
            // complete initial byte stream to the caller.
            guard var readySubscription = subscriptions[subscriptionId],
                  readySubscription.bootstrap.hasSnapshotBoundary,
                  let readyContext = readers[paneId],
                  readyContext.reader === context.reader,
                  readyContext.subscriberIds.contains(subscriptionId) else {
                await rollbackBootstrap(
                    subscriptionId: subscriptionId,
                    paneId: paneId
                )
                throw TmuxError.invalidPane(target: target)
            }
            let initialContent = readySubscription.bootstrap.finish(with: snapshot)
            subscriptions[subscriptionId] = readySubscription
            let width = readyContext.width
            let height = readyContext.height

            if let title = readyContext.terminalTitle, let cb = onTitleChange {
                cb(title)
            }

            logger.info("Subscriber ready on pane reader", metadata: [
                "paneId": "\(paneId)",
                "target": "\(target)",
                "subscriptionId": "\(subscriptionId)",
                "totalSubscribers": "\(readyContext.subscriberIds.count)",
            ])

            return SubscriptionResult(
                subscriptionId: subscriptionId,
                initialContent: initialContent,
                width: width,
                height: height,
                scrollbackLineLimit: viewerScrollbackLineLimit
            )
        }

        /// Unsubscribe from a pane stream.
        ///
        /// If this is the last subscriber, control-mode output is disabled. The
        /// scan-only OSC reader stays attached until the pane disappears.
        ///
        /// - Parameter subscriptionId: The subscription ID returned from subscribe()
        public func unsubscribe(_ subscriptionId: UUID) async {
            guard let subscription = subscriptions.removeValue(forKey: subscriptionId) else {
                logger.debug("Subscription not found: \(subscriptionId)")
                return
            }

            let paneId = subscription.paneId
            pendingResyncRequests.remove(subscriptionId: subscriptionId, paneId: paneId)

            guard var context = readers[paneId] else {
                logger.warning("Reader not found for pane: \(paneId)")
                return
            }

            context.subscriberIds.remove(subscriptionId)
            readers[paneId] = context

            if context.subscriberIds.isEmpty {
                try? await controlClientManager.setPaneOutputEnabled(
                    paneId: paneId,
                    sessionName: context.sessionName,
                    enabled: false
                )
                logger.info("Last subscriber gone, control output disabled", metadata: [
                    "paneId": "\(paneId)",
                ])
            } else {
                logger.info("Removed subscriber from reader", metadata: [
                    "paneId": "\(paneId)",
                    "subscriptionId": "\(subscriptionId)",
                    "remainingSubscribers": "\(context.subscriberIds.count)",
                ])
            }
        }

        /// Update dimensions for a pane (called when tmux refreshes pane info).
        ///
        /// A real size change is an authoritative snapshot boundary. Subscribers
        /// first adopt the new geometry, then one pane-wide resync replaces every
        /// mirror before buffered live bytes resume.
        public func updateDimensions(paneId: String, width: Int, height: Int) {
            guard var context = readers[paneId] else { return }
            guard let boundary = PaneDimensionResyncBoundary(
                currentWidth: context.width,
                currentHeight: context.height,
                newWidth: width,
                newHeight: height,
                subscriptionIds: context.subscriberIds
            ) else { return }
            context.width = boundary.width
            context.height = boundary.height
            readers[paneId] = context
            forwardDimensionChange(
                paneId: paneId,
                width: boundary.width,
                height: boundary.height
            )
            requestResync(paneId: paneId, subscriptionIds: boundary.subscriptionIds)
        }

        /// Report a terminal title change detected by a subscriber's SwiftTerm instance.
        ///
        /// SwiftTerm parses OSC 0/2 sequences from the data stream and calls its delegate.
        /// The subscriber (e.g., TerminalContainerView) reports the title back here so it can
        /// be forwarded to other subscribers (e.g., TerminalStreamService for iOS relay).
        ///
        /// - Parameters:
        ///   - paneId: The pane ID whose title changed
        ///   - title: The new terminal title
        ///   - fromSubscription: The subscription ID reporting the change (excluded from forwarding)
        public func reportTitleChange(paneId: String, title: String, fromSubscription: UUID) {
            guard var context = readers[paneId] else { return }
            guard !title.isEmpty, context.terminalTitle != title else { return }
            context.terminalTitle = title
            readers[paneId] = context

            // Notify global handler so MirrorWindowManager stays in sync
            // even when the pane is streamed without a local mirror window
            onTitleChange?(paneId, context.target, title)

            forwardTitleChange(paneId: paneId, title: title, excludingSubscription: fromSubscription)
        }

        /// Captures current content for a pane that is already streaming.
        ///
        /// A second remote viewer reuses the existing PaneStreamManager
        /// subscription. Its private downstream bootstrap buffer is cut at
        /// `onSnapshotBoundary`, ordered against live output on the same control
        /// connection, so it receives exactly `snapshot + post-boundary bytes`.
        ///
        /// - Parameter paneId: The pane ID to capture content for
        /// - Returns: Current content, width, and height if the pane has subscribers; nil otherwise
        public func currentContent(
            for paneId: String,
            maximumSnapshotScrollbackLineLimit: Int? = nil,
            onSnapshotBoundary: (@MainActor @Sendable () -> Void)? = nil
        ) async -> (content: Data, width: Int, height: Int, scrollbackLineLimit: Int)? {
            guard var context = readers[paneId], !context.subscriberIds.isEmpty else { return nil }
            if let dimensions = try? await tmuxService.getPaneDimensions(context.target) {
                guard var refreshed = readers[paneId], refreshed.reader === context.reader else {
                    return nil
                }
                refreshed.width = dimensions.width
                refreshed.height = dimensions.height
                readers[paneId] = refreshed
                context = refreshed
            }
            let viewerScrollbackLineLimit = configuredScrollbackLineLimit
            let snapshotScrollbackLineLimit = resolvedSnapshotScrollbackLineLimit(
                maximum: maximumSnapshotScrollbackLineLimit
            )
            guard
                let content = try? await tmuxService.capturePaneViaControlMode(
                    paneId: paneId,
                    width: context.width,
                    height: context.height,
                    controlClientManager: controlClientManager,
                    sessionName: context.sessionName,
                    scrollbackLineLimit: snapshotScrollbackLineLimit,
                    onSnapshotBoundary: onSnapshotBoundary
                )
            else {
                return nil
            }
            return (content, context.width, context.height, viewerScrollbackLineLimit)
        }

        /// Requests an authoritative snapshot for one subscription. Concurrent
        /// requests for the same pane share one capture and are notified before
        /// buffered live bytes are flushed.
        func requestResync(subscriptionId: UUID) {
            guard
                let subscription = subscriptions[subscriptionId],
                let context = readers[subscription.paneId]
            else { return }
            // Buffering and forward suppression are pane-wide. Every existing
            // subscriber therefore crosses the same snapshot boundary, even
            // when only one downstream queue requested recovery.
            requestResync(
                paneId: subscription.paneId,
                subscriptionIds: context.subscriberIds
            )
        }

        private func requestResync(paneId: String, subscriptionIds: Set<UUID>) {
            guard !subscriptionIds.isEmpty else { return }
            pendingResyncRequests.request(paneId: paneId, subscriptionIds: subscriptionIds)
            resyncingPaneIds.insert(paneId)
            startResyncTaskIfNeeded(paneId: paneId)
        }

        private func startResyncTaskIfNeeded(paneId: String) {
            guard resyncTasks[paneId] == nil else { return }
            resyncTasks[paneId] = Task { @MainActor [weak self] in
                await self?.runResyncLoop(paneId: paneId)
            }
        }

        /// Returns DEC private mode escape sequences to enable the pane's current mouse tracking mode.
        ///
        /// `capture-pane` only records text and SGR attributes, not terminal state like mouse
        /// tracking mode. Remote viewers need these sequences fed into SwiftTerm so their
        /// terminal reflects the host's mouse mode — otherwise mouse events are treated as local
        /// selection/scroll until the application redraws and re-emits the enable sequence.
        ///
        /// - Parameter paneId: The pane ID to query
        /// - Returns: Escape sequence bytes (empty if mouse mode is off or the pane is not known)
        public func mouseModeSequences(for paneId: String) async -> Data {
            guard let context = readers[paneId] else { return Data() }
            let mode: TmuxService.PaneMouseMode
            do {
                mode = try await tmuxService.getPaneMouseMode(context.target)
            } catch {
                logger.debug("Failed to query mouse mode, defaulting to off", metadata: [
                    "paneId": "\(paneId)",
                    "error": "\(error)",
                ])
                return Data()
            }

            var sequences = ""
            switch mode {
            case .standard:
                sequences += "\u{1b}[?1000h"
            case .button:
                sequences += "\u{1b}[?1002h"
            case .any:
                sequences += "\u{1b}[?1003h"
            case .off:
                return Data()
            }
            // SGR encoding is almost always paired with mouse tracking.
            sequences += "\u{1b}[?1006h"
            return Data(sequences.utf8)
        }

        /// Disconnect all readers (called on app shutdown).
        public func disconnectAll() async {
            isShuttingDown = true
            await readerStartGate.cancelAll()

            let paneIds = Array(readers.keys)
            for paneId in paneIds {
                await tearDownReader(paneId: paneId)
            }
            subscriptions.removeAll()
            pendingResyncRequests.removeAll()
            resyncingPaneIds.removeAll()
            resyncBootstraps.removeAll()
            paneRefreshTask?.cancel()
            paneRefreshTask = nil
            logger.info("Disconnected all pane readers")
        }

        // MARK: - Pane Lifecycle

        /// Start readers for all panes not already known. Called once on
        /// startup after initial pane discovery.
        public func startMonitoring(panes: [PaneInfo]) async {
            for pane in panes where readers[pane.paneId] == nil {
                let seedTitle = isCustomPaneTitle(pane.paneTitle) ? pane.paneTitle : nil
                await ensureReader(
                    paneId: pane.paneId,
                    sessionName: pane.sessionName,
                    target: pane.target,
                    initialWidth: pane.width,
                    initialHeight: pane.height,
                    seedTitle: seedTitle
                )
            }
        }

        /// Update readers based on the current pane list.
        ///
        /// Tears down readers for dead panes, starts readers for new panes,
        /// and seeds custom tmux pane titles that the OSC reader missed
        /// (e.g. set during async startup before pipe-pane attached).
        public func updateMonitoring(panes: [PaneInfo]) async {
            let currentPaneIds = Set(panes.map(\.paneId))
            let previousSessionPaneIds = Dictionary(grouping: readers, by: { $0.value.sessionName })
                .mapValues { Set($0.map(\.key)) }
            let currentSessionPaneIds = Dictionary(grouping: panes, by: \.sessionName)
                .mapValues { Set($0.map(\.paneId)) }

            // A moved pane also changes its textual target. Only rekey the
            // session-wide control client when the old session disappeared and
            // its complete pane-ID set reappeared under one new name.
            let renamedSessions = SessionRenameMapping.detectNames(
                from: previousSessionPaneIds,
                to: currentSessionPaneIds
            )
            for (oldName, newName) in renamedSessions {
                await controlClientManager.sessionRenamed(from: oldName, to: newName)
            }

            let staleIds = readers.keys.filter { !currentPaneIds.contains($0) }
            for paneId in staleIds {
                await tearDownReader(paneId: paneId)
            }

            for pane in panes where readers[pane.paneId] == nil {
                let seedTitle = isCustomPaneTitle(pane.paneTitle) ? pane.paneTitle : nil
                await ensureReader(
                    paneId: pane.paneId,
                    sessionName: pane.sessionName,
                    target: pane.target,
                    initialWidth: pane.width,
                    initialHeight: pane.height,
                    seedTitle: seedTitle
                )
            }

            // `%layout-change` is the low-latency path, but control-mode events
            // can be missed during reconnect. The periodic tmux snapshot is the
            // authority, so reconcile every existing reader as well as newly
            // created ones and forward any correction to live subscribers.
            for pane in panes {
                updateDimensions(paneId: pane.paneId, width: pane.width, height: pane.height)
            }

            // `rename-session` preserves pane IDs and live pipe-pane readers,
            // but every textual target changes. Update the reader context so
            // capture, mouse-mode and teardown commands stop using the old target.
            for pane in panes {
                guard var context = readers[pane.paneId] else { continue }
                guard context.target != pane.target || context.sessionName != pane.sessionName else { continue }
                context.target = pane.target
                context.sessionName = pane.sessionName
                readers[pane.paneId] = context
            }

            // Seed/update custom titles missed by the OSC reader (e.g. titles
            // tmux already had before pipe-pane attached).
            for pane in panes where isCustomPaneTitle(pane.paneTitle) {
                guard var context = readers[pane.paneId] else { continue }
                guard context.terminalTitle != pane.paneTitle else { continue }
                context.terminalTitle = pane.paneTitle
                readers[pane.paneId] = context
                onTitleChange?(pane.paneId, pane.target, pane.paneTitle)
            }
        }

        /// Start periodic pane discovery to detect new tmux sessions.
        ///
        /// Control clients only detect changes within their own session;
        /// new tmux sessions need periodic discovery.
        public func startPeriodicPaneRefresh(tmuxService: TmuxService) {
            paneRefreshTask?.cancel()
            paneRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled else { break }
                    let panes = await tmuxService.refreshPanes()
                    await self?.updateMonitoring(panes: panes)
                }
            }
        }

        // MARK: - Reader Lifecycle Helpers

        @discardableResult
        private func ensureReader(
            paneId: String,
            sessionName: String,
            target: String,
            initialWidth: Int,
            initialHeight: Int,
            seedTitle: String?
        ) async -> Bool {
            guard !isShuttingDown else { return false }
            if readers[paneId] != nil { return true }

            return await readerStartGate.run(paneId: paneId) { [weak self] in
                guard let self, !self.isShuttingDown else { return false }
                if self.readers[paneId] != nil { return true }
                return await self.startReader(
                    paneId: paneId,
                    sessionName: sessionName,
                    target: target,
                    initialWidth: initialWidth,
                    initialHeight: initialHeight,
                    seedTitle: seedTitle
                )
            }
        }

        private func startReader(
            paneId: String,
            sessionName: String,
            target: String,
            initialWidth: Int,
            initialHeight: Int,
            seedTitle: String?
        ) async -> Bool {
            let reader = PipePaneReader(paneId: paneId, fifoDirectory: fifoDirectory)
            await reader.setDelegate(self)

            do {
                try await reader.startPipePane(
                    controlClientManager: controlClientManager,
                    sessionName: sessionName
                )
                guard
                    !Task.isCancelled,
                    !isShuttingDown,
                    await reader.isHealthy
                else {
                    await reader.stopPipePane(
                        controlClientManager: controlClientManager,
                        sessionName: sessionName
                    )
                    return false
                }
                readers[paneId] = ReaderContext(
                    reader: reader,
                    target: target,
                    sessionName: sessionName,
                    width: initialWidth,
                    height: initialHeight,
                    subscriberIds: [],
                    terminalTitle: seedTitle,
                    hasRegisteredDimensions: false
                )
                if let seedTitle {
                    onTitleChange?(paneId, target, seedTitle)
                }
                logger.debug("Started reader", metadata: ["paneId": "\(paneId)"])
                return true
            } catch {
                logger.debug("Failed to start reader", metadata: [
                    "paneId": "\(paneId)",
                    "error": "\(error)",
                ])
                return false
            }
        }

        private func tearDownReader(paneId: String) async {
            if let task = readerRecoveryTasks.removeValue(forKey: paneId) {
                task.cancel()
                _ = await task.value
            }
            if let task = resyncTasks.removeValue(forKey: paneId) {
                task.cancel()
                _ = await task.value
            }
            pendingResyncRequests.discard(paneId: paneId)
            resyncingPaneIds.remove(paneId)
            resyncBootstraps.removeValue(forKey: paneId)

            guard let context = readers.removeValue(forKey: paneId) else { return }

            try? await controlClientManager.setPaneOutputEnabled(
                paneId: paneId,
                sessionName: context.sessionName,
                enabled: false
            )

            // Drop subscriptions belonging to this pane (caller likely already
            // unsubscribed, but this guards against shutdown ordering bugs).
            for subId in context.subscriberIds {
                subscriptions.removeValue(forKey: subId)
            }

            await context.reader.stopPipePane(
                controlClientManager: controlClientManager,
                sessionName: context.sessionName
            )

            if context.hasRegisteredDimensions {
                await controlClientManager.unregisterPane(
                    paneId: paneId,
                    sessionName: context.sessionName
                )
            }

            logger.debug("Tore down reader", metadata: ["paneId": "\(paneId)"])
        }

        // MARK: - PipePaneReaderDelegate

        public func pipePaneReader(
            _ paneId: String,
            didReceiveNotification notification: TerminalStreamMessage.TerminalNotification
        ) {
            forwardNotification(paneId: paneId, notification: notification)
        }

        public func pipePaneReader(_ paneId: String, didReceiveTitle title: String) {
            handleStreamTitleChange(paneId: paneId, title: title)
        }

        public func pipePaneReader(_ paneId: String, didReceiveClipboard content: String) {
            forwardClipboard(paneId: paneId, content: content)
        }

        public func pipePaneReader(_ paneId: String, didReceiveProgress progress: TerminalProgressState) {
            onProgress?(paneId, progress)
        }

        func pipePaneReader(
            _ reader: PipePaneReader,
            paneId: String,
            didTerminate reason: PipePaneReaderTermination
        ) {
            guard
                !isShuttingDown,
                readers[paneId]?.reader === reader,
                readerRecoveryTasks[paneId] == nil
            else { return }

            logger.warning("Recovering terminated pane reader", metadata: [
                "paneId": "\(paneId)",
                "reason": "\(reason)",
            ])
            readerRecoveryTasks[paneId] = Task { @MainActor [weak self] in
                await self?.recoverReader(paneId: paneId, reader: reader)
            }
        }

        // MARK: - Private Forwarding

        private func handleControlOutput(paneId: String, data: Data) {
            TerminalTransportMetrics.shared.recordLocalOutput(paneId: paneId)
            forwardData(paneId: paneId, data: data)
        }

        private func forwardData(paneId: String, data: Data) {
            if resyncingPaneIds.contains(paneId) {
                if var bootstrap = resyncBootstraps[paneId] {
                    _ = bootstrap.route(data)
                    resyncBootstraps[paneId] = bootstrap
                }
                // Pending subscriptions have their own snapshot boundaries.
                // Keep feeding their private buffers, even while live mirrors
                // are suppressed behind the pane-wide resync boundary.
                for subscriberId in readers[paneId]?.subscriberIds ?? [] {
                    guard var subscription = subscriptions[subscriberId],
                          subscription.bootstrap.isCollecting else { continue }
                    _ = subscription.bootstrap.route(data)
                    subscriptions[subscriberId] = subscription
                }
                return
            }
            guard let context = readers[paneId] else { return }

            for subscriberId in context.subscriberIds {
                guard var subscription = subscriptions[subscriberId] else { continue }
                let liveData = subscription.bootstrap.route(data)
                subscriptions[subscriberId] = subscription
                if let liveData {
                    subscription.onData(liveData)
                }
            }
        }

        /// Removes a failed bootstrap without disturbing subscribers that were
        /// already live. If it was the first subscriber, disable control output.
        private func rollbackBootstrap(
            subscriptionId: UUID,
            paneId: String
        ) async {
            subscriptions.removeValue(forKey: subscriptionId)
            guard var context = readers[paneId] else { return }
            context.subscriberIds.remove(subscriptionId)
            readers[paneId] = context

            if context.subscriberIds.isEmpty {
                try? await controlClientManager.setPaneOutputEnabled(
                    paneId: paneId,
                    sessionName: context.sessionName,
                    enabled: false
                )
            }
        }

        /// Restarts the notification-only FIFO reader without disturbing the
        /// terminal stream, whose bytes use the independent control connection.
        private func recoverReader(paneId: String, reader: PipePaneReader) async {
            defer {
                readerRecoveryTasks[paneId] = nil
            }

            while !Task.isCancelled, !isShuttingDown {
                guard let context = readers[paneId], context.reader === reader else { return }

                await reader.stopPipePane(
                    controlClientManager: controlClientManager,
                    sessionName: context.sessionName
                )
                guard !Task.isCancelled, !isShuttingDown else { return }
                guard readers[paneId]?.reader === reader else { return }

                do {
                    try await reader.startPipePane(
                        controlClientManager: controlClientManager,
                        sessionName: context.sessionName
                    )
                } catch {
                    logger.warning("Failed to restart pane reader; retrying", metadata: [
                        "paneId": "\(paneId)",
                        "error": "\(error)",
                    ])
                }

                if await reader.isHealthy {
                    guard readers[paneId]?.reader === reader else { return }
                    logger.info("Recovered notification-only pane reader", metadata: [
                        "paneId": "\(paneId)",
                    ])
                    return
                }

                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        private func runResyncLoop(paneId: String) async {
            defer {
                resyncTasks[paneId] = nil
                resyncingPaneIds.remove(paneId)
                resyncBootstraps.removeValue(forKey: paneId)
            }

            while !Task.isCancelled {
                guard
                    pendingResyncRequests.hasRequests(paneId: paneId),
                    let originalContext = readers[paneId]
                else { return }
                // Consume this round before suspending. A new request from the
                // same subscriber must remain visible for a following capture.
                let targets = pendingResyncRequests.take(paneId: paneId)

                resyncBootstraps[paneId] = PaneSubscriptionBootstrap()
                let dimensions = try? await tmuxService.getPaneDimensions(originalContext.target)
                // MainActor is reentrant across the query. Never write back the
                // pre-await context: subscribers may have joined/left, or the
                // title/session metadata may have changed while it was pending.
                // Revalidate even on query failure and do not revive a reader
                // whose resync was cancelled by teardown.
                guard !Task.isCancelled, !isShuttingDown,
                      var context = readers[paneId],
                      context.reader === originalContext.reader else { return }
                if let dimensions {
                    context.width = dimensions.width
                    context.height = dimensions.height
                    readers[paneId] = context
                }

                let viewerScrollbackLineLimit = configuredScrollbackLineLimit
                let snapshotScrollbackLineLimit = context.subscriberIds
                    .compactMap { subscriptions[$0] }
                    .map {
                        resolvedSnapshotScrollbackLineLimit(
                            maximum: $0.maximumSnapshotScrollbackLineLimit
                        )
                    }
                    .max() ?? viewerScrollbackLineLimit
                let captured: Data
                do {
                    captured = try await tmuxService.capturePaneViaControlMode(
                        paneId: paneId,
                        width: context.width,
                        height: context.height,
                        controlClientManager: controlClientManager,
                        sessionName: context.sessionName,
                        scrollbackLineLimit: snapshotScrollbackLineLimit,
                        onSnapshotBoundary: { [weak self] in
                            guard var bootstrap = self?.resyncBootstraps[paneId] else { return }
                            bootstrap.markSnapshotBoundary()
                            self?.resyncBootstraps[paneId] = bootstrap
                        }
                    )
                } catch {
                    if Task.isCancelled { return }
                    let failureTargets = targets
                        .union(readers[paneId]?.subscriberIds ?? [])
                        .union(pendingResyncRequests.take(paneId: paneId))
                    for subscriptionId in failureTargets {
                        guard let subscription = subscriptions[subscriptionId],
                              !subscription.bootstrap.isCollecting else { continue }
                        subscription.onResync?(.failure(error))
                    }
                    logger.error("Failed to resynchronize pane stream", metadata: [
                        "paneId": "\(paneId)",
                        "error": "\(error)",
                    ])
                    return
                }

                guard !Task.isCancelled, !isShuttingDown,
                      readers[paneId]?.reader === context.reader else { return }
                guard var bootstrap = resyncBootstraps[paneId], bootstrap.hasSnapshotBoundary else {
                    logger.error("Missing ordered snapshot boundary", metadata: [
                        "paneId": "\(paneId)",
                    ])
                    return
                }

                TerminalTransportMetrics.shared.recordResync()
                // Output was suppressed pane-wide, including for subscribers
                // that finished joining during capture. All currently live
                // subscribers must receive this snapshot before the tail.
                let currentSubscriberIds = readers[paneId]?.subscriberIds ?? []
                for subscriptionId in currentSubscriberIds {
                    guard let subscription = subscriptions[subscriptionId],
                          !subscription.bootstrap.isCollecting else { continue }
                    subscription.onResync?(.success(SubscriptionResult(
                        subscriptionId: subscriptionId,
                        initialContent: captured,
                        width: context.width,
                        height: context.height,
                        scrollbackLineLimit: viewerScrollbackLineLimit
                    )))
                }

                // Reset callbacks are synchronous MainActor work. Only bytes
                // emitted after the visible capture's `%end` are replayed.
                let postSnapshotData = bootstrap.finish(with: Data())
                resyncBootstraps.removeValue(forKey: paneId)
                resyncingPaneIds.remove(paneId)
                if !postSnapshotData.isEmpty {
                    for subscriptionId in currentSubscriberIds {
                        guard let subscription = subscriptions[subscriptionId],
                              !subscription.bootstrap.isCollecting else { continue }
                        // Collecting subscriptions already buffered these bytes
                        // against their private boundary; never append twice.
                        subscription.onData(postSnapshotData)
                    }
                }

                guard pendingResyncRequests.hasRequests(paneId: paneId) else { return }
                resyncingPaneIds.insert(paneId)
            }
        }

        private func forwardDimensionChange(paneId: String, width: Int, height: Int) {
            guard let context = readers[paneId] else { return }

            for subscriberId in context.subscriberIds {
                if
                    let subscription = subscriptions[subscriberId],
                    !subscription.bootstrap.isCollecting,
                    let callback = subscription.onDimensionChange {
                    callback(width, height)
                }
            }
        }

        private func forwardTitleChange(paneId: String, title: String, excludingSubscription: UUID?) {
            guard let context = readers[paneId] else { return }

            for subscriberId in context.subscriberIds where subscriberId != excludingSubscription {
                if
                    let subscription = subscriptions[subscriberId],
                    let callback = subscription.onTitleChange {
                    callback(title)
                }
            }
        }

        /// Handle title change detected by the per-pane reader (from raw pipe-pane data).
        /// Updates the reader context and forwards to all subscribers and the global handler.
        private func handleStreamTitleChange(paneId: String, title: String) {
            guard var context = readers[paneId] else { return }
            guard !title.isEmpty, context.terminalTitle != title else { return }
            context.terminalTitle = title
            readers[paneId] = context

            // Notify global handler (MirrorWindowManager)
            onTitleChange?(paneId, context.target, title)

            // Forward to all subscribers
            forwardTitleChange(paneId: paneId, title: title, excludingSubscription: nil)
        }

        private func forwardClipboard(paneId: String, content: String) {
            guard let context = readers[paneId] else { return }
            for subscriberId in context.subscriberIds {
                if
                    let subscription = subscriptions[subscriberId],
                    let callback = subscription.onClipboard {
                    callback(content)
                }
            }
        }

        private func forwardNotification(
            paneId: String,
            notification: TerminalStreamMessage.TerminalNotification
        ) {
            // Call global handler unconditionally — desktop notifications fire
            // even for panes that aren't being mirrored.
            onNotification?(paneId, notification)

            // Forward to per-subscriber handlers (only if a stream has subscribers)
            guard let context = readers[paneId] else { return }
            for subscriberId in context.subscriberIds {
                if
                    let subscription = subscriptions[subscriberId],
                    let callback = subscription.onNotification {
                    callback(notification)
                }
            }
        }
    }

#endif
