import AppKit
import CtrlxCommon
import CtrlxNetworking
import SwiftTerm
import SwiftUI

// MARK: - State Change Callback

/// Callback type for reporting terminal state changes to parent view
typealias TerminalStateChangeHandler = @MainActor (StreamState, Int, Int) -> Void

/// Callback type for reporting terminal title changes to parent view
typealias TerminalTitleChangeHandler = @MainActor (String) -> Void

/// Callback type for handling URL clicks in the terminal. Returns `true` if the
/// callback handled the URL, `false` to fall back to `NSWorkspace.shared.open`.
typealias TerminalOpenURLHandler = @MainActor (URL) -> Bool

/// Tracks the last pane dimensions delivered by SwiftUI so width-only and
/// height-only layout changes are both observed exactly once.
struct TerminalDimensionChangeTracker {
    private var width: Int?
    private var height: Int?

    mutating func record(width newWidth: Int, height newHeight: Int) -> Bool {
        guard width != newWidth || height != newHeight else { return false }
        width = newWidth
        height = newHeight
        return true
    }
}

// MARK: - Terminal Container View

/// A self-contained SwiftUI view that mirrors a tmux pane.
///
/// This view handles everything internally:
/// - Creates and manages the terminal view
/// - Connects to the pane stream
/// - Feeds data to the terminal
/// - Handles dimension changes
/// - Reports state back to parent via callback
struct TerminalContainerView: NSViewRepresentable {
    let paneState: PaneState
    /// When false, the terminal won't auto-grab focus on window add or window-becomes-key.
    /// Used in multi-pane layouts where multiple terminals share one window.
    var autoFocus = true
    /// Shows a focus outline when this terminal is one tile in a multi-pane layout.
    var showsFocusIndicator = false
    let onStateChange: TerminalStateChangeHandler?
    let onTitleChange: TerminalTitleChangeHandler?
    var onOpenURL: TerminalOpenURLHandler?
    /// Fires whenever this terminal becomes the window's first responder.
    /// Used to mirror focus back to tmux so external clients see the same active pane.
    var onFocus: (@MainActor () -> Void)?

    @Environment(AppSettings.self) private var settings
    @Environment(TmuxService.self) private var tmuxService
    @Environment(PaneStreamManager.self) private var paneStreamManager
    @Environment(EditorSessionManager.self) private var editorSessionManager
    @Environment(\.terminalQuickActions) private var quickActions

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveTerminalView {
        let coordinator = context.coordinator

        // Configure auto-focus before starting (must be set before viewDidMoveToWindow fires).
        // Same applies to isEditorActive: if a pane tile is (re)created while an editor
        // session is already active on that pane (e.g., tab switch), viewDidMoveToWindow
        // would otherwise auto-grab focus before updateNSView flips the flag.
        coordinator.terminalView.autoFocusEnabled = autoFocus
        coordinator.terminalView.showsFocusIndicator = showsFocusIndicator
        coordinator.terminalView.isEditorActive =
            editorSessionManager.session(for: paneState.paneId) != nil

        // Start the coordinator with all dependencies
        coordinator.start(
            paneState: paneState,
            tmuxService: tmuxService,
            paneStreamManager: paneStreamManager,
            settings: settings,
            onStateChange: onStateChange,
            onTitleChange: onTitleChange
        )

        // URL-click handler is set on every layout pass so it picks up fresh
        // state captured by parent closures (window/session selection).
        coordinator.terminalView.onOpenURL = onOpenURL
        coordinator.bindQuickActions(quickActions, onFocus: onFocus)

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
        let coordinator = context.coordinator

        nsView.showsFocusIndicator = showsFocusIndicator

        // Update editor state — suppress keyboard/focus when editor overlay is active
        let editorActive = editorSessionManager.session(for: paneState.paneId) != nil
        let wasEditorActive = nsView.isEditorActive
        nsView.isEditorActive = editorActive

        // When editor just closed, restore focus to the terminal
        if wasEditorActive, !editorActive {
            nsView.focusTerminal()
        }

        // Update pane state — tmux rearranges pane indices when panes are
        // added or removed, so the target (e.g., "session:0.1") can change.
        // The coordinator must track the current target for key routing.
        coordinator.updatePaneState(paneState)

        // Update settings if changed
        coordinator.updateSettings(settings)

        // Re-bind the URL click handler so closures captured here reflect the
        // current parent state on every layout pass.
        nsView.onOpenURL = onOpenURL
        coordinator.bindQuickActions(quickActions, onFocus: onFocus)

        // Update container size on layout changes
        coordinator.updateContainerSize(nsView.frame.size)

        // Check for dimension changes from pane state (updated after %layout-change)
        coordinator.handleExternalDimensionChange(width: paneState.width, height: paneState.height)
    }

    static func dismantleNSView(_ nsView: InteractiveTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: @unchecked Sendable {
        // MARK: Views

        let terminalView: InteractiveTerminalView

        // MARK: Services (held for lifetime)

        private weak var paneStreamManager: PaneStreamManager?
        private weak var tmuxService: TmuxService?

        // MARK: State

        private var paneState: PaneState?
        private(set) var quickActionEndpoint: TerminalQuickActionEndpoint?
        private weak var quickActionRouter: TerminalQuickActionRouter?
        private var subscriptionId: UUID?
        private var streamState: StreamState = .disconnected
        private var columns = 80
        private var rows = 24
        private var externalDimensionTracker = TerminalDimensionChangeTracker()
        /// When connected, rows are locked to the tmux pane height so that
        /// absolute cursor positioning in live `%output` maps correctly.
        private var rowsLockedToTmux = false

        private var fontName: String?
        private var fontSize: CGFloat?
        private var scrollbackLineLimit: Int?
        private var containerSize: NSSize = .zero

        private var onStateChange: TerminalStateChangeHandler?
        private var onTitleChange: TerminalTitleChangeHandler?

        /// Track initial scroll state
        private var hasScrolledInitial = false

        // Track consecutive key send failures for error reporting
        private var consecutiveKeyFailures = 0
        private let maxConsecutiveKeyFailures = 3

        /// Serializes key sends so concurrent onInput callbacks don't race.
        /// Keys flow through `keyCoalescer`, which chains onto this task on the
        /// *next* runloop turn, while raw input chains synchronously — so the raw
        /// path calls `keyCoalescer.flushPending()` first to keep key-vs-raw FIFO.
        /// File drop (a heavyweight paste) is intentionally off this chain, so its
        /// ordering relative to keystrokes is best-effort.
        private var pendingKeyTask: Task<Void, Never>?
        private var pendingInputBatchCount = 0
        private var pendingInputBytes = 0
        private var inputGeneration: UInt64 = 0
        private let transportMetrics = TerminalTransportMetrics.shared

        /// Coalesces the two synchronous `send()` callbacks SwiftTerm emits for a
        /// Meta/Option sequence (ESC + key) into one batch, sent as a single
        /// `send-keys` so the app sees one Meta keypress. See `KeystrokeCoalescer`.
        private lazy var keyCoalescer = KeystrokeCoalescer { [weak self] batch in
            guard let self, let paneState = self.paneState else { return }
            let token = self.transportMetrics.beginLocalInput(
                paneId: paneState.paneId,
                acceptedAt: batch.acceptedAt
            )
            let byteCount = batch.keys.reduce(0) { $0 + max(1, $1.tmuxKeyName.utf8.count) }
            let generation = self.inputGeneration
            self.addPendingInput(byteCount: byteCount, paneId: paneState.paneId)
            let previous = self.pendingKeyTask
            self.pendingKeyTask = Task { @MainActor [weak self] in
                _ = await previous?.value
                guard let self, !Task.isCancelled, self.inputGeneration == generation else {
                    self?.transportMetrics.discardLocalInput(token)
                    return
                }
                defer { self.removePendingInput(byteCount: byteCount, paneId: paneState.paneId) }
                self.transportMetrics.recordLocalInput(token, stage: .sendStarted)
                await self.sendKeysToTmux(
                    batch.keys,
                    paneId: paneState.paneId,
                    target: paneState.target,
                    metricsToken: token
                )
            }
        }

        /// Limits SwiftTerm parsing/drawing to a bounded MainActor time slice.
        /// Pending keyboard input forces smaller chunks and a yield after each
        /// feed while preserving the exact terminal byte order.
        private lazy var feedCoalescer = TerminalFeedCoalescer(
            id: "local:\(paneState?.paneId ?? "unknown")",
            maximumFeedBytes: 8_192,
            prioritizedFeedBytes: 4_096,
            maximumTurnDuration: .milliseconds(2),
            shouldPrioritizeInput: { [weak self] in
                guard let self else { return false }
                return self.pendingInputBatchCount > 0 || self.keyCoalescer.hasPendingKeys
            }
        ) { [weak self] data in
            self?.feedDataNow(data)
        }

        // MARK: Initialization

        init() {
            self.terminalView = InteractiveTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            // Disable custom block glyph rendering. SwiftTerm's drawBoxDrawings snaps cell
            // widths to integer pixels (baseCellWidthPx), while text uses fractional
            // cellDimension.width. For non-integer cell widths (e.g. SF Mono 12pt = 7.42pt),
            // this causes cumulative positioning drift — up to ~42pt at column 100 on non-Retina.
            // Using the font's own box drawing glyphs keeps them on the same text grid.
            terminalView.customBlockGlyphs = false
            terminalView.applyTheme(.defaultDark)
        }

        // MARK: Lifecycle

        func start(
            paneState: PaneState,
            tmuxService: TmuxService,
            paneStreamManager: PaneStreamManager,
            settings: AppSettings,
            onStateChange: TerminalStateChangeHandler?,
            onTitleChange: TerminalTitleChangeHandler?
        ) {
            self.paneState = paneState
            self.paneStreamManager = paneStreamManager
            self.tmuxService = tmuxService
            self.onStateChange = onStateChange
            self.onTitleChange = onTitleChange
            quickActionEndpoint = TerminalQuickActionEndpoint(
                hostID: nil, paneID: paneState.paneId,
                isVisible: { [weak self] in
                    guard let view = self?.terminalView else { return false }
                    return view.window != nil && !view.isHiddenOrHasHiddenAncestor
                },
                enqueue: { [weak self] keys in
                    guard let self else { return }
                    self.keyCoalescer.enqueueImmediately(keys)
                }
            )
            _ = externalDimensionTracker.record(width: paneState.width, height: paneState.height)

            terminalView.terminalAccessibilityIdentifier = "terminal-\(paneState.paneId)"

            // Apply initial settings
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            updateScrollbackLineLimit(settings.scrollbackLines)
            terminalView.applyTheme(settings.theme)

            // Wire up input handling. SwiftTerm emits a Meta/Option sequence as
            // TWO synchronous send() callbacks — a lone ESC, then the key — so we
            // coalesce keys that land in the same runloop turn into one batch (see
            // `keyCoalescer.enqueue`). Sent as separate `send-keys` calls, tmux
            // delivers a bare Escape followed by the key, so Option-Backspace only
            // deletes one character; batched into a single `send-keys` they arrive
            // as the intended Meta combination (ESC DEL → delete word).
            terminalView.onInput = { [weak self] keys in
                self?.quickActionEndpoint?.recordInput()
                self?.keyCoalescer.enqueue(keys)
            }

            // Wire up raw input (mouse escape sequences) — same serialization chain.
            // The coalescer defers its `pendingKeyTask` chaining to the next runloop
            // turn, so flush any keys buffered earlier in *this* turn first; that
            // chains them ahead of this raw send and keeps overall input FIFO.
            terminalView.onRawInput = { [weak self] data in
                guard let self, let paneState = self.paneState else { return }
                self.quickActionEndpoint?.recordInput()
                self.keyCoalescer.flushPending()
                let generation = self.inputGeneration
                let byteCount = data.count
                self.addPendingInput(byteCount: byteCount, paneId: paneState.paneId)
                let previous = self.pendingKeyTask
                self.pendingKeyTask = Task { @MainActor [weak self] in
                    _ = await previous?.value
                    guard let self, !Task.isCancelled, self.inputGeneration == generation else { return }
                    defer { self.removePendingInput(byteCount: byteCount, paneId: paneState.paneId) }
                    await self.sendRawBytesToTmux(data, target: paneState.target)
                }
            }

            // Wire up file-drop forwarding. For the local mirror the dropped
            // paths are already addressable on the host filesystem, so we
            // skip the SendDroppedFiles round-trip and paste the paths
            // straight into tmux's bracketed-paste buffer.
            terminalView.onFileDrop = { [weak self] urls in
                guard let self, let paneState = self.paneState else { return }
                self.quickActionEndpoint?.recordInput()
                Task {
                    await self.handleLocalFileDrop(urls: urls, target: paneState.target)
                }
            }

            // Wire up title change handling
            terminalView.onTitleChange = { [weak self] title in
                self?.handleTitleChange(title)
            }

            // Start connection
            Task {
                await connect(paneState: paneState, tmuxService: tmuxService)
            }
        }

        // MARK: - Input Handling

        private func sendKeysToTmux(
            _ keys: [TmuxKey],
            paneId: String,
            target: String,
            metricsToken: TerminalTransportMetrics.LocalInputToken
        ) async {
            guard let tmuxService else {
                transportMetrics.failLocalInput(metricsToken)
                return
            }

            do {
                let sentThroughControlMode = if let paneStreamManager {
                    try await paneStreamManager.sendKeystrokesIfConnected(
                        paneId: paneId,
                        keys: keys,
                        onFirstCommandWritten: { [metrics = transportMetrics] in
                            metrics.recordLocalInput(metricsToken, stage: .tmuxWrite)
                        }
                    )
                } else {
                    false
                }

                if !sentThroughControlMode {
                    transportMetrics.recordLocalInput(metricsToken, stage: .tmuxWrite)
                    try await tmuxService.sendKeystrokes(target, keys: keys)
                }
                transportMetrics.recordLocalInput(metricsToken, stage: .tmuxAcknowledged)
                consecutiveKeyFailures = 0
            } catch {
                transportMetrics.failLocalInput(metricsToken)
                consecutiveKeyFailures += 1
                print("Failed to send keys to tmux: \(error)")

                if consecutiveKeyFailures >= maxConsecutiveKeyFailures {
                    updateState(.error("Failed to send keystrokes to tmux"))
                }
            }
        }

        private func sendRawBytesToTmux(_ data: Data, target: String) async {
            guard let tmuxService else { return }

            do {
                try await tmuxService.sendRawBytes(target, data: data)
                consecutiveKeyFailures = 0
            } catch {
                consecutiveKeyFailures += 1
                print("Failed to send raw bytes to tmux: \(error)")

                if consecutiveKeyFailures >= maxConsecutiveKeyFailures {
                    updateState(.error("Failed to send mouse events to tmux"))
                }
            }
        }

        private func handleLocalFileDrop(urls: [URL], target: String) async {
            guard
                let tmuxService,
                let content = DroppedPathFormatter.format(urls: urls)
            else { return }
            do {
                // Per-drop buffer name. The host's tmux command queue isn't
                // strictly ordered across our async load/paste pair (the
                // process spawn for one drop's `paste-buffer` can land after
                // the next drop's `load-buffer` if the user drops twice
                // quickly), so a stable name like `ctrlx-drop` would lose
                // the first drop's contents under that race. The UUID suffix
                // gives each drop its own buffer; `-d` cleans them up.
                try await tmuxService.loadAndPasteBuffer(
                    target: target,
                    content: content,
                    bufferName: "ctrlx-drop-\(UUID().uuidString.prefix(8))"
                )
            } catch {
                print("Failed to paste dropped files into tmux: \(error)")
            }
        }

        /// Updates the pane state when tmux rearranges pane indices.
        /// The `onInput` closure reads `self.paneState.target` on each call,
        /// so updating the stored state is sufficient — no closure re-wiring needed.
        func updatePaneState(_ newState: PaneState) {
            paneState = newState
        }

        func bindQuickActions(_ router: TerminalQuickActionRouter?, onFocus: (@MainActor () -> Void)?) {
            quickActionRouter = router
            terminalView.onBecomeFirstResponder = { [weak self] in
                if let self, let endpoint = self.quickActionEndpoint {
                    self.quickActionRouter?.focus(endpoint)
                }
                onFocus?()
            }
        }

        func stop() {
            if let endpoint = quickActionEndpoint {
                endpoint.invalidate()
                let router = quickActionRouter
                Task { @MainActor in router?.retire(endpoint) }
            }
            terminalView.onBecomeFirstResponder = nil
            // Disconnect input handlers first so no new tmux commands fire
            // after the pane is destroyed (prevents SIGABRT from NSTask).
            terminalView.onInput = nil
            terminalView.onRawInput = nil
            terminalView.onFileDrop = nil

            pendingKeyTask?.cancel()
            pendingKeyTask = nil
            inputGeneration &+= 1
            pendingInputBatchCount = 0
            pendingInputBytes = 0
            if let paneId = paneState?.paneId {
                transportMetrics.clearQueue(.localInput, id: paneId)
            }
            keyCoalescer.reset()
            feedCoalescer.discardPending()
            rowsLockedToTmux = false
            terminalView.lockedDimensions = nil
            guard let subId = subscriptionId else { return }
            let manager = paneStreamManager
            Task {
                await manager?.unsubscribe(subId)
            }
            subscriptionId = nil
            // Don't call updateState here - the view is being dismantled
            // and updating @State during teardown causes a crash
        }

        // MARK: Connection

        private func connect(paneState: PaneState, tmuxService: TmuxService) async {
            updateState(.connecting)

            // Get initial dimensions from tmux. Rows must match the tmux pane
            // so that absolute cursor positioning in live %output events maps correctly.
            do {
                let dims = try await tmuxService.getPaneDimensions(paneState.target)
                updateTerminalDimensions(cols: dims.width, rows: dims.height)
            } catch {
                updateTerminalDimensions(cols: paneState.width, rows: paneState.height)
            }

            clear()

            // Subscribe to stream
            guard let paneStreamManager else {
                updateState(.error("Stream manager unavailable"))
                return
            }

            do {
                let target = paneState.target
                // Note: onTitleChange is intentionally omitted here. Title changes are detected
                // locally by SwiftTerm's delegate (terminalView.onTitleChange) and then reported
                // back to PaneStreamManager via reportTitleChange(), which forwards to other
                // subscribers. This avoids a circular callback loop.
                let result = try await paneStreamManager.subscribe(
                    paneId: paneState.paneId,
                    target: target,
                    onData: { [weak self] data in
                        self?.handleData(data)
                    },
                    onDimensionChange: { [weak self] newWidth, newHeight in
                        self?.handleStreamDimensionChange(width: newWidth, height: newHeight)
                    },
                    onResync: { [weak self] result in
                        self?.handleResync(result)
                    }
                )

                subscriptionId = result.subscriptionId
                updateState(.connected)

                // Update dimensions from result
                updateTerminalDimensions(cols: result.width, rows: result.height)

                // Feed initial content to terminal
                if !result.initialContent.isEmpty {
                    handleData(result.initialContent)
                }

                // capture-pane doesn't include DEC private mode state (mouse
                // tracking). Query tmux for the pane's mouse flags and inject
                // the enable sequences so SwiftTerm enters the correct mode.
                await syncMouseMode(target: target, tmuxService: tmuxService)
            } catch {
                updateState(.error(error.localizedDescription))
            }
        }

        // MARK: Title Handling

        private func handleTitleChange(_ title: String) {
            // Notify the parent view
            onTitleChange?(title)

            // Report to PaneStreamManager so other subscribers (e.g., TerminalStreamService) are notified
            if let paneState, let subscriptionId {
                paneStreamManager?.reportTitleChange(
                    paneId: paneState.paneId,
                    title: title,
                    fromSubscription: subscriptionId
                )
            }
        }

        // MARK: Data Handling

        private func handleData(_ data: Data) {
            feedCoalescer.enqueue(data)
        }

        private func feedDataNow(_ data: Data) {
            let bytes = [UInt8](data)[...]

            if !hasScrolledInitial {
                // First data - feed and enable scroll preservation.
                // Don't scrollToBottom here: for terminals taller than the viewport,
                // scrolling to bottom shows empty rows and hides the prompt at the top.
                // SwiftTerm's natural rendering starts from the top which is correct.
                terminalView.feed(byteArray: bytes)
                terminalView.preserveUserScroll = true
                hasScrolledInitial = true
            } else {
                // Subsequent data - preserve user's scroll position
                terminalView.feedPreservingScroll(bytes)
            }
            if let paneId = paneState?.paneId {
                transportMetrics.recordLocalFeed(paneId: paneId)
            }
        }

        private func addPendingInput(byteCount: Int, paneId: String) {
            pendingInputBatchCount += 1
            pendingInputBytes += byteCount
            recordPendingInput(paneId: paneId)
        }

        private func removePendingInput(byteCount: Int, paneId: String) {
            pendingInputBatchCount = max(0, pendingInputBatchCount - 1)
            pendingInputBytes = max(0, pendingInputBytes - byteCount)
            recordPendingInput(paneId: paneId)
        }

        private func recordPendingInput(paneId: String) {
            transportMetrics.recordQueue(
                .localInput,
                id: paneId,
                depth: pendingInputBatchCount,
                bytes: pendingInputBytes
            )
        }

        private func handleResync(_ result: Result<PaneStreamManager.SubscriptionResult, Error>) {
            switch result {
            case let .success(snapshot):
                updateTerminalDimensions(cols: snapshot.width, rows: snapshot.height)
                feedCoalescer.replace(with: snapshot.initialContent) { [weak self] in
                    guard let self else { return }
                    hasScrolledInitial = false
                    terminalView.getTerminal().resetToInitialState()
                    terminalView.preserveUserScroll = false
                }
                terminalView.preserveUserScroll = true

                if let paneState, let tmuxService {
                    Task { [weak self] in
                        await self?.syncMouseMode(target: paneState.target, tmuxService: tmuxService)
                    }
                }

            case let .failure(error):
                updateState(.error("Terminal resync failed: \(error.localizedDescription)"))
            }
        }

        // MARK: Mouse Mode Sync

        /// Queries the tmux pane's mouse tracking flags and injects the
        /// corresponding DEC private mode sequences into SwiftTerm.
        /// `capture-pane` only captures text + SGR attributes, not terminal
        /// state like mouse mode, so the mirror must sync this separately.
        private func syncMouseMode(target: String, tmuxService: TmuxService) async {
            do {
                let result = try await tmuxService.getPaneMouseMode(target)
                guard result != .off else { return }

                var sequences = ""
                switch result {
                case .standard:
                    sequences += "\u{1b}[?1000h"
                case .button:
                    sequences += "\u{1b}[?1002h"
                case .any:
                    sequences += "\u{1b}[?1003h"
                case .off:
                    break
                }
                // SGR encoding (almost always paired with mouse tracking)
                if result != .off {
                    sequences += "\u{1b}[?1006h"
                }

                terminalView.feed(byteArray: Array(sequences.utf8)[...])
            } catch {
                // Non-fatal — mouse just won't work until the app redraws
            }
        }

        // MARK: Terminal Operations

        func feed(_ data: Data) {
            let bytes = [UInt8](data)
            terminalView.feed(byteArray: bytes[...])
        }

        func clear() {
            feed(Data("\u{1b}[2J\u{1b}[H".utf8))
        }

        /// Updates terminal dimensions from tmux pane size.
        /// Rows are locked to the tmux pane height so that absolute cursor
        /// positioning in live `%output` events maps correctly to mirror rows.
        @discardableResult
        func updateTerminalDimensions(cols newColumns: Int, rows newRows: Int) -> Bool {
            let changed = newColumns != columns || newRows != rows
            columns = newColumns
            rows = newRows
            rowsLockedToTmux = true
            // Lock dimensions on the terminal view so its sizeChanged delegate
            // can re-apply them when SwiftTerm's async processSizeChange fires.
            terminalView.lockedDimensions = (cols: columns, rows: rows)
            if changed {
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                updateTerminalFrameSize()
                reapplyDimensionsIfNeeded()
                notifyStateChange()
            }
            return changed
        }

        func scrollToBottom() {
            terminalView.scroll(toPosition: 1)
        }

        func updateContainerSize(_ size: NSSize) {
            guard size != containerSize else { return }
            containerSize = size
            recalculateRowsAndResize()
        }

        // MARK: Settings

        func updateSettings(_ settings: AppSettings) {
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            updateScrollbackLineLimit(settings.scrollbackLines)
            terminalView.applyTheme(settings.theme)
            terminalView.autoCopyOnSelect = settings.autoCopyOnSelect
        }

        private func updateScrollbackLineLimit(_ requested: Int) {
            let lineLimit = TerminalScrollbackPolicy.normalizedLineLimit(requested)
            guard lineLimit != scrollbackLineLimit else { return }
            scrollbackLineLimit = lineLimit
            terminalView.changeScrollback(lineLimit)
        }

        private func updateFont(name: String, size: CGFloat) {
            guard
                name != fontName || size != fontSize else { return }
            fontName = name
            fontSize = size

            let font = NSFont(name: name, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            terminalView.font = font
            updateTerminalFrameSize()
            // SwiftTerm's resetFont() recalculates cols/rows from frame.width
            // without subtracting scroller width. Re-apply our correct dimensions.
            reapplyDimensionsIfNeeded()
        }

        // MARK: External Dimension Changes

        func handleExternalDimensionChange(width: Int, height: Int) {
            guard externalDimensionTracker.record(width: width, height: height) else { return }

            // Resize terminal immediately to avoid cursor misposition.
            // Without this, the shell's prompt redraw (via pipe-pane) arrives
            // while the terminal still has the old grid, then absolute cursor
            // positions can land outside the visible mirror.
            updateTerminalDimensions(cols: width, rows: height)

            // The shared stream manager turns the size change into one
            // authoritative reset for every local and remote subscriber.
            paneStreamManager?.updateDimensions(paneId: paneState?.paneId ?? "", width: width, height: height)
        }

        private func handleStreamDimensionChange(width: Int, height: Int) {
            updateTerminalDimensions(cols: width, rows: height)
        }

        // MARK: Private Helpers

        /// Recalculates rows based on container height and resizes terminal.
        /// When rows are locked to tmux pane height, only re-applies locked
        /// dimensions — frame updates are skipped to avoid triggering SwiftTerm's
        /// processSizeChange which would override the locked row count.
        private func recalculateRowsAndResize() {
            guard rows > 0 else { return }

            if rowsLockedToTmux {
                // When locked, skip row recalculation but still update the
                // frame size so the terminal width tracks the container.
                // setTerminalSize uses locked optimal height (not bounds.height)
                // to avoid triggering processSizeChange row recalculation.
                updateTerminalFrameSize()
                reapplyDimensionsIfNeeded()
                return
            }

            // Derive cell height from SwiftTerm's optimal frame size
            let currentOptimalSize = terminalView.getOptimalFrameSize().size
            let cellHeight = currentOptimalSize.height / CGFloat(rows)
            guard cellHeight > 0 else { return }

            // Calculate rows from container height
            let newRows = max(1, Int(containerSize.height / cellHeight))

            if newRows != rows {
                rows = newRows
                terminalView.getTerminal().resize(cols: columns, rows: rows)
                notifyStateChange()
            }

            updateTerminalFrameSize()
            reapplyDimensionsIfNeeded()
        }

        // MARK: - Size Calculations

        private func updateTerminalFrameSize() {
            // Let SwiftTerm tell us the optimal size - it knows its own cell dimensions and scroller width
            let optimalSize = terminalView.getOptimalFrameSize().size
            terminalView.setTerminalSize(optimalSize)
        }

        /// Re-applies the correct terminal dimensions if SwiftTerm's internal
        /// sizing logic (processSizeChange/resetFont) has overridden them.
        /// This happens because setTerminalSize uses bounds.height which may
        /// not be an exact multiple of cellHeight * rows, causing SwiftTerm
        /// to recalculate different dimensions.
        private func reapplyDimensionsIfNeeded() {
            let terminal = terminalView.getTerminal()
            if terminal.cols != columns || terminal.rows != rows {
                terminal.resize(cols: columns, rows: rows)
            }
        }

        private func updateState(_ state: StreamState) {
            streamState = state
            quickActionEndpoint?.isReady = state == .connected
            notifyStateChange()
        }

        private func notifyStateChange() {
            onStateChange?(streamState, columns, rows)
        }
    }
}
