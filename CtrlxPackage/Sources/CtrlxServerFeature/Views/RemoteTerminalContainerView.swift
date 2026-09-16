import AppKit
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import SwiftTerm
import SwiftUI

// MARK: - Remote Terminal Container View

/// Displays a live terminal from a remote host, streaming data via the relay server.
///
/// This is the macOS counterpart to the iOS `LiveTerminalView`, using the same
/// `ViewerRelayClient` for terminal streaming and keystroke forwarding.
struct RemoteTerminalContainerView: View {
    let paneId: String
    let hostName: String
    let connection: ViewerConnection
    let settings: AppSettings
    /// The stable window key used by MirrorWindowManager to track this window
    var windowKey: String?
    var onStreamEnd: (() -> Void)?
    /// Whether to show the per-pane status bar (defaults to using the app setting)
    var showStatusBar: Bool?
    /// True when a prompt editor overlay is active above this terminal.
    /// Suppresses keyboard forwarding to the remote tmux pane so the editor gets input.
    var isEditorActive = false
    /// When false, the terminal won't auto-grab focus on window add or window-becomes-key.
    /// Used in multi-pane layouts where multiple terminals share one window.
    var autoFocus = true
    /// Shows a focus outline when this terminal is one tile in a multi-pane layout.
    var showsFocusIndicator = false
    /// Fires whenever this terminal becomes the window's first responder.
    /// Used to mirror focus back to the remote tmux via `SelectTmuxPane`.
    var onFocus: (@MainActor () -> Void)?
    /// Handler invoked when a URL is clicked inside the terminal. Returning
    /// `true` consumes the click; `false` lets `InteractiveTerminalView` fall
    /// back to `URLOpener` (system default browser). Wire this so remote
    /// sessions honour the same `browserLinkBehavior` flow as local ones.
    var onOpenURL: TerminalOpenURLHandler?

    @State private var streamState: RemoteStreamState = .connecting
    @State private var streamWidth = 80
    @State private var streamHeight = 24
    @State private var terminalTitle: String?
    @State private var upload: UploadState?
    @State private var streamRetryGeneration = 0

    private var windowTitle: String {
        if let terminalTitle, !terminalTitle.isEmpty {
            return terminalTitle
        }
        return "Remote: \(hostName) - \(paneId)"
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteTerminalNSView(
                paneId: paneId,
                connection: connection,
                isHostConnected: connection.isHostConnected,
                retryGeneration: streamRetryGeneration,
                settings: settings,
                isEditorActive: isEditorActive,
                autoFocus: autoFocus,
                showsFocusIndicator: showsFocusIndicator,
                onFocus: onFocus,
                onOpenURL: onOpenURL,
                onStateChange: { state, width, height in
                    streamState = state
                    streamWidth = width
                    streamHeight = height
                },
                onTitleChange: { title in
                    terminalTitle = title
                },
                onImagePaste: { image in
                    startImageUpload(image)
                },
                onFileDrop: { urls in
                    startFileDropUpload(urls)
                },
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: settings.theme.palette.background.nativeColor))
            .overlay {
                if streamState == .connecting {
                    Color(nsColor: settings.theme.palette.background.nativeColor)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("remote-terminal-bootstrap")
                } else if case let .error(message) = streamState {
                    ContentUnavailableView(
                        "Terminal Stream Error",
                        symbol: .exclamationmarkTriangle,
                        description: message,
                    ) {
                        Button("Retry") {
                            streamRetryGeneration &+= 1
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connection.isHostConnected)
                        .accessibilityIdentifier("remote-terminal-retry")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(settings.theme.workspaceBackgroundColor.opacity(0.96))
                }
            }
            .overlay(alignment: .center) {
                if let upload {
                    UploadOverlay(state: upload, onCancel: cancelUpload)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: upload?.id)

            if showStatusBar ?? settings.showStatusBar {
                statusBar
            }
        }
        // Only set the navigation title when this view owns its window
        // (i.e. used as a standalone mirror window). When embedded as a tile in
        // RemoteWindowPaneLayoutView, the parent's title must remain in effect.
        .standaloneNavigationTitle(windowTitle, when: windowKey != nil)
        .onChange(of: terminalTitle) { _, newTitle in
            // Update the NSWindow title to match (SwiftUI navigationTitle doesn't sync to NSWindow)
            guard let newTitle, !newTitle.isEmpty, let windowKey else { return }
            // Use the stable window key for lookup instead of searching by title contents,
            // which would break after the first title update changes the window title.
            NSApp.windows.first { $0.identifier?.rawValue == windowKey }?.title = newTitle
        }
        .onChange(of: streamState) { _, newState in
            if newState == .disconnected {
                onStreamEnd?()
            }
        }
        // Tear down any in-flight upload or auto-dismiss timer when the view
        // is removed from the hierarchy (e.g. window closed mid-failure),
        // so detached tasks don't survive the view that owned them.
        .onDisappear {
            cancelUpload()
        }
    }

    private func startImageUpload(_ image: ClipboardImage) {
        // Cancel any in-flight upload before starting a new one. Two rapid
        // Cmd+V presses should not race two upload commands at the host,
        // and a rapid second paste should also short-circuit any in-flight
        // failure auto-dismiss timer.
        upload?.cancel()

        let task = Task { @MainActor in
            // Clipboard TIFFs can be tens of times larger than their PNG form.
            // Normalize and, only when necessary, resize/compress off the main
            // actor before constructing the base64 command payload.
            let prepared = await Task.detached(priority: .userInitiated) {
                RelayImagePreparer.prepare(
                    image,
                    maxBytes: SendDroppedFiles.maxRawBytes
                )
            }.value
            if Task.isCancelled { return }

            guard let prepared else {
                let message = String(
                    format: "Unable to optimize this image for the relay's %d KB limit.",
                    SendDroppedFiles.maxRawBytes / 1_024
                )
                upload = .failed(
                    kind: .image,
                    sizeBytes: image.data.count,
                    message: message,
                    dismissTask: dismissTimer(after: .seconds(4))
                )
                return
            }

            // Refresh the overlay with the bytes that will actually cross the
            // relay while preserving the task and animation identity.
            if case let .uploading(id, _, _, currentTask) = upload {
                upload = .uploading(
                    id: id,
                    kind: .image,
                    sizeBytes: prepared.data.count,
                    task: currentTask
                )
            }

            // The image rides the same `SendDroppedFiles` flow Finder drops use.
            // The host saves it under $TMPDIR and bracketed-pastes its path.
            let name = "pasted-image-\(UUID().uuidString).\(prepared.format.fileExtension)"
            let file = DroppedFile(name: name, data: prepared.data)
            let result = await connection.relayClient.sendCommand(
                SendDroppedFiles(files: [file]),
                paneId: paneId,
                timeout: 30
            )
            // Treat cancellation as silent — the user already saw the popover
            // dismiss when they hit Cancel and we don't want a transient
            // "failed" flash to take its place.
            if Task.isCancelled { return }
            switch result {
            case .success:
                upload = nil
            case let .failure(error):
                if error is CancellationError {
                    upload = nil
                } else {
                    upload = .failed(
                        kind: .image,
                        sizeBytes: prepared.data.count,
                        message: error.localizedDescription,
                        dismissTask: dismissTimer(after: .seconds(3))
                    )
                }
            }
        }
        upload = .uploading(kind: .image, sizeBytes: image.data.count, task: task)
    }

    /// Reads each dropped file's bytes off-main-actor and ships them as a
    /// single `SendDroppedFiles` command. The host saves them to `$TMPDIR`
    /// and pastes the resolved paths via tmux's bracketed-paste buffer.
    private func startFileDropUpload(_ urls: [URL]) {
        upload?.cancel()
        guard !urls.isEmpty else { return }

        let task = Task { @MainActor in
            // Read off the main actor — `Data(contentsOf:)` synchronously
            // reads the whole file, and we shouldn't block UI for large drops.
            // The detached task also returns the running total so the @MainActor
            // side never has to base64-decode each `DroppedFile.data` again
            // just to learn its size.
            let readResult = await Task.detached {
                () -> Result<(files: [DroppedFile], totalBytes: Int), Error> in
                do {
                    var entries: [DroppedFile] = []
                    var total = 0
                    for url in urls {
                        let data = try Data(contentsOf: url)
                        total += data.count
                        if total > SendDroppedFiles.maxRawBytes {
                            throw FileDropError.tooLarge(totalBytes: total)
                        }
                        entries.append(DroppedFile(name: url.lastPathComponent, data: data))
                    }
                    return .success((entries, total))
                } catch {
                    return .failure(error)
                }
            }.value

            if Task.isCancelled { return }

            switch readResult {
            case let .success((files, totalBytes)):
                // Now that we know the real size, refresh the in-flight upload
                // state so the overlay shows actual bytes instead of the 0 B
                // placeholder it carried while the read was running. Preserve
                // the existing `id` and `task` so SwiftUI doesn't trigger a new
                // transition and `cancelUpload()` keeps tearing down the same
                // task.
                if case let .uploading(id, _, _, currentTask) = upload {
                    upload = .uploading(
                        id: id,
                        kind: .files(count: files.count),
                        sizeBytes: totalBytes,
                        task: currentTask
                    )
                }
                let result = await connection.relayClient.sendCommand(
                    SendDroppedFiles(files: files),
                    paneId: paneId,
                    timeout: 30
                )
                if Task.isCancelled { return }
                switch result {
                case .success:
                    upload = nil
                case let .failure(error):
                    if error is CancellationError {
                        upload = nil
                    } else {
                        upload = .failed(
                            kind: .files(count: files.count),
                            sizeBytes: totalBytes,
                            message: error.localizedDescription,
                            dismissTask: dismissTimer(after: .seconds(3))
                        )
                    }
                }
            case let .failure(error):
                let message: String
                if case let FileDropError.tooLarge(totalBytes) = error {
                    let mb = Double(totalBytes) / (1_024 * 1_024)
                    message = String(
                        format: "Dropped files total %.1f MB. The relay only supports drops under %d KB.",
                        mb,
                        SendDroppedFiles.maxRawBytes / 1_024
                    )
                } else {
                    message = error.localizedDescription
                }
                upload = .failed(
                    kind: .files(count: urls.count),
                    sizeBytes: 0,
                    message: message,
                    dismissTask: dismissTimer(after: .seconds(4))
                )
            }
        }
        upload = .uploading(kind: .files(count: urls.count), sizeBytes: 0, task: task)
    }

    /// Spawns an auto-dismiss timer that clears `upload` after the given
    /// duration. Returned so the caller can cancel it if a new upload starts
    /// before the timer fires.
    private func dismissTimer(after delay: Duration) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled {
                upload = nil
            }
        }
    }

    private func cancelUpload() {
        upload?.cancel()
        upload = nil
    }

    private var statusBar: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
            }

            Divider()
                .frame(height: 12)

            Text("\(streamWidth)x\(streamHeight)")

            Spacer()

            Text(hostName)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(settings.theme.chromeBackgroundColor)
    }

    private var statusColor: SwiftUI.Color {
        switch streamState {
        case .streaming: .green
        case .connecting: .orange
        case .disconnected: .gray
        case .error: .red
        }
    }

    private var statusText: String {
        switch streamState {
        case .streaming: "Streaming"
        case .connecting: "Connecting..."
        case .disconnected: "Disconnected"
        case let .error(message): "Error: \(message)"
        }
    }
}

// MARK: - Upload State

/// What kind of payload an `UploadState` represents — drives only the user-
/// facing label so the same overlay works for image pastes and file drops.
private enum UploadKind: Equatable {
    case image
    case files(count: Int)
}

/// Local error type for off-main-actor file reads.
private enum FileDropError: Error {
    case tooLarge(totalBytes: Int)
}

/// Transient state for an in-flight or just-failed image paste / file drop.
/// Each case owns the task whose cancellation will tear down the matching UI
/// — the in-flight relay request for `.uploading`, the auto-dismiss timer for
/// `.failed`. We carry a per-state `id` so SwiftUI's `.animation(value:)` can
/// drive a transition between consecutive uploads without forcing Equatable
/// on `Task`, which is a reference type.
private enum UploadState {
    case uploading(id: UUID, kind: UploadKind, sizeBytes: Int, task: Task<Void, Never>)
    case failed(
        id: UUID,
        kind: UploadKind,
        sizeBytes: Int,
        message: String,
        dismissTask: Task<Void, Never>
    )

    static func uploading(
        kind: UploadKind,
        sizeBytes: Int,
        task: Task<Void, Never>
    ) -> UploadState {
        .uploading(id: UUID(), kind: kind, sizeBytes: sizeBytes, task: task)
    }

    static func failed(
        kind: UploadKind,
        sizeBytes: Int,
        message: String,
        dismissTask: Task<Void, Never>
    ) -> UploadState {
        .failed(
            id: UUID(),
            kind: kind,
            sizeBytes: sizeBytes,
            message: message,
            dismissTask: dismissTask
        )
    }

    var id: UUID {
        switch self {
        case let .uploading(id, _, _, _),
             let .failed(id, _, _, _, _):
            id
        }
    }

    var kind: UploadKind {
        switch self {
        case let .uploading(_, kind, _, _),
             let .failed(_, kind, _, _, _):
            kind
        }
    }

    var sizeBytes: Int {
        switch self {
        case let .uploading(_, _, sizeBytes, _),
             let .failed(_, _, sizeBytes, _, _):
            sizeBytes
        }
    }

    var failureMessage: String? {
        if case let .failed(_, _, _, message, _) = self { return message }
        return nil
    }

    func cancel() {
        switch self {
        case let .uploading(_, _, _, task):
            task.cancel()
        case let .failed(_, _, _, _, dismissTask):
            dismissTask.cancel()
        }
    }
}

// MARK: - Upload Overlay

/// Popover-style overlay shown while an image paste or file drop is being
/// forwarded to the remote host. Includes a cancel button so a user can
/// abort large uploads.
private struct UploadOverlay: View {
    let state: UploadState
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if state.failureMessage == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                Symbols.exclamationmarkTriangle.image
                    .fontWeight(.bold)
                    .foregroundStyle(.yellow)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headlineText)
                    .font(.headline)
                Text(state.failureMessage ?? sizeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if state.failureMessage == nil {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("upload-overlay-cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator)
        }
        .shadow(radius: 8, y: 2)
        .accessibilityIdentifier("upload-overlay")
    }

    private var headlineText: String {
        switch (state.kind, state.failureMessage) {
        case (.image, .none):
            return "Sending image…"
        case (.image, .some):
            return "Image paste failed"
        case let (.files(count), .none):
            return count == 1 ? "Sending file…" : "Sending \(count) files…"
        case (.files, .some):
            return "File drop failed"
        }
    }

    private var sizeDescription: String {
        let bytes = Double(state.sizeBytes)
        if bytes >= 1_024 * 1_024 {
            return String(format: "%.1f MB", bytes / (1_024 * 1_024))
        }
        if bytes >= 1_024 {
            return String(format: "%.0f KB", bytes / 1_024)
        }
        return "\(state.sizeBytes) B"
    }
}

#Preview("Uploading image") {
    UploadOverlay(
        state: .uploading(kind: .image, sizeBytes: 412_000, task: Task { }),
        onCancel: { }
    )
    .padding(40)
    .background(Color.gray.opacity(0.3))
}

#Preview("Image failed") {
    UploadOverlay(
        state: .failed(
            kind: .image,
            sizeBytes: 1_572_864,
            message: "Image is 1.5 MB. The relay only supports images under 700 KB.",
            dismissTask: Task { }
        ),
        onCancel: { }
    )
    .padding(40)
    .background(Color.gray.opacity(0.3))
}

#Preview("Sending files") {
    UploadOverlay(
        state: .uploading(kind: .files(count: 3), sizeBytes: 0, task: Task { }),
        onCancel: { }
    )
    .padding(40)
    .background(Color.gray.opacity(0.3))
}

// MARK: - Stream State

enum RemoteStreamState: Equatable {
    case connecting
    case streaming
    case disconnected
    case error(String)
}

// MARK: - NSViewRepresentable

/// NSViewRepresentable that wraps an InteractiveTerminalView for remote terminal streaming.
private struct RemoteTerminalNSView: NSViewRepresentable {
    @Environment(\.terminalQuickActions) private var quickActions
    let paneId: String
    let connection: ViewerConnection
    let isHostConnected: Bool
    let retryGeneration: Int
    let settings: AppSettings
    let isEditorActive: Bool
    let autoFocus: Bool
    let showsFocusIndicator: Bool
    let onFocus: (@MainActor () -> Void)?
    let onOpenURL: TerminalOpenURLHandler?
    let onStateChange: @MainActor (RemoteStreamState, Int, Int) -> Void
    let onTitleChange: @MainActor (String) -> Void
    let onImagePaste: @MainActor (ClipboardImage) -> Void
    let onFileDrop: @MainActor ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveTerminalView {
        let coordinator = context.coordinator

        // Configure auto-focus before starting (must be set before viewDidMoveToWindow fires).
        coordinator.terminalView.autoFocusEnabled = autoFocus
        coordinator.terminalView.showsFocusIndicator = showsFocusIndicator

        coordinator.start(
            paneId: paneId,
            connection: connection,
            isHostConnected: isHostConnected,
            retryGeneration: retryGeneration,
            settings: settings,
            onStateChange: onStateChange,
            onTitleChange: onTitleChange,
        )
        coordinator.terminalView.isEditorActive = isEditorActive
        coordinator.bindQuickActions(quickActions, onFocus: onFocus)
        coordinator.terminalView.onOpenURL = onOpenURL
        // Route image pastes through the SwiftUI parent so the upload state
        // and cancel popover live alongside the terminal view in the body
        // hierarchy. Returning `true` consumes the paste — `Ctrl+V` is sent
        // by the host once it has the bytes on its pasteboard.
        coordinator.terminalView.onImagePaste = { [weak coordinator] image in
            coordinator?.quickActionEndpoint?.recordInput()
            onImagePaste(image)
            return true
        }
        // Same shape as image paste: let the SwiftUI parent run the upload
        // overlay; the host will save the files and dispatch the paste once
        // the bytes have arrived.
        coordinator.terminalView.onFileDrop = { [weak coordinator] urls in
            coordinator?.quickActionEndpoint?.recordInput()
            onFileDrop(urls)
        }

        return coordinator.terminalView
    }

    func updateNSView(_ nsView: InteractiveTerminalView, context: Context) {
        let coordinator = context.coordinator
        nsView.showsFocusIndicator = showsFocusIndicator
        context.coordinator.updateSettings(settings)
        context.coordinator.updateContainerSize(nsView.frame.size)
        context.coordinator.synchronizeStream(
            isHostConnected: isHostConnected,
            retryGeneration: retryGeneration,
        )

        // Re-bind focus, paste and URL-click callbacks so closures captured
        // here reflect the current parent state on every layout pass.
        context.coordinator.bindQuickActions(quickActions, onFocus: onFocus)
        nsView.onOpenURL = onOpenURL
        nsView.onImagePaste = { [weak coordinator] image in
            coordinator?.quickActionEndpoint?.recordInput()
            onImagePaste(image)
            return true
        }
        nsView.onFileDrop = { [weak coordinator] urls in
            coordinator?.quickActionEndpoint?.recordInput()
            onFileDrop(urls)
        }

        // Update editor-active flag. When the editor just closed, restore first
        // responder to the terminal so typing resumes without a manual click.
        let wasEditorActive = nsView.isEditorActive
        nsView.isEditorActive = isEditorActive
        if wasEditorActive, !isEditorActive, !nsView.isHidden {
            nsView.focusTerminal()
        }
    }

    static func dismantleNSView(_ nsView: InteractiveTerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: @unchecked Sendable {
        let terminalView: InteractiveTerminalView
        @Dependency(ClipboardClient.self) private var clipboard

        private var paneId: String?
        private(set) var quickActionEndpoint: TerminalQuickActionEndpoint?
        private weak var quickActionRouter: TerminalQuickActionRouter?
        private weak var connection: ViewerConnection?
        private var streamSubscriptionId: UUID?
        private var streamAttemptId: UUID?
        private var activeLeaseId: UUID?
        private var streamState: RemoteStreamState = .connecting
        private var columns = 80
        private var rows = 24
        private var fontName: String?
        private var fontSize: CGFloat?
        private var scrollbackLineLimit: Int?
        private var containerSize: NSSize = .zero
        private var bootstrapPolicy = TerminalStreamBootstrapPolicy()
        private var bootstrapBuffer = TerminalStreamBootstrapBuffer()
        private var bootstrapAccumulator = TerminalStreamSnapshotAccumulator()
        private var resetAccumulator = TerminalStreamSnapshotAccumulator()
        private var pendingResetState: TerminalStreamMessage.InitialState?
        private var streamTask: Task<Void, Never>?
        private var lastIsHostConnected: Bool?
        private var lastRetryGeneration: Int?
        private var recoveryPolicy = TerminalStreamRecoveryPolicy()
        private var onStateChange: (@MainActor (RemoteStreamState, Int, Int) -> Void)?
        private var onTitleChange: (@MainActor (String) -> Void)?

        private var keystrokeDebouncer: KeystrokeDebouncer?
        private lazy var keyCoalescer = KeystrokeCoalescer { [weak self] batch in
            self?.enqueueKeySend(keys: batch.keys)
        }

        private lazy var feedCoalescer = TerminalFeedCoalescer(
            id: "mac-remote:\(paneId ?? "unknown")"
        ) { [weak self] data in
            guard let terminalView = self?.terminalView else { return }
            terminalView.feedPreservingScroll([UInt8](data)[...])
        }

        init() {
            self.terminalView = InteractiveTerminalView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600)
            )
            // Disable custom block glyph rendering — see TerminalContainerView.init for details.
            terminalView.customBlockGlyphs = false
            terminalView.applyTheme(.defaultDark)
            updateScrollbackLineLimit(TerminalScrollbackPolicy.defaultLineLimit)
            terminalView.isHidden = true
        }

        func start(
            paneId: String,
            connection initialConnection: ViewerConnection,
            isHostConnected: Bool,
            retryGeneration: Int,
            settings: AppSettings,
            onStateChange: @MainActor @escaping (RemoteStreamState, Int, Int) -> Void,
            onTitleChange: @MainActor @escaping (String) -> Void,
        ) {
            self.paneId = paneId
            connection = initialConnection
            self.onStateChange = onStateChange

            terminalView.terminalAccessibilityIdentifier = "terminal-\(paneId)"
            self.onTitleChange = onTitleChange
            quickActionEndpoint = TerminalQuickActionEndpoint(
                hostID: initialConnection.id, paneID: paneId,
                isVisible: { [weak self] in
                    guard let view = self?.terminalView else { return false }
                    return view.window != nil && !view.isHiddenOrHasHiddenAncestor
                },
                enqueue: { [weak self] keys in
                    guard let self else { return }
                    self.keyCoalescer.enqueueImmediately(keys)
                }
            )

            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            terminalView.applyTheme(settings.theme)

            // Wire keystroke forwarding via relay
            terminalView.onInput = { [weak self] keys in
                guard
                    let self,
                    streamState == .streaming,
                    let connection,
                    connection.isHostConnected
                else { return }
                quickActionEndpoint?.recordInput()
                keyCoalescer.enqueue(keys)
            }

            // Wire raw input (mouse escape sequences) forwarding via relay
            terminalView.onRawInput = { [weak self] data in
                guard
                    let self,
                    streamState == .streaming,
                    let connection,
                    connection.isHostConnected
                else { return }
                quickActionEndpoint?.recordInput()
                keyCoalescer.flushPending()
                enqueueRawInput(data: data, connection: connection)
            }

            // Subscribe to terminal stream for this specific pane
            let subscriptionId = initialConnection.subscribeToTerminalStream(paneId: paneId) { [weak self] message in
                self?.handleStreamMessage(message)
            }
            streamSubscriptionId = subscriptionId

            synchronizeStream(
                isHostConnected: isHostConnected,
                retryGeneration: retryGeneration,
            )
        }

        func synchronizeStream(isHostConnected: Bool, retryGeneration: Int) {
            let connectionChanged = lastIsHostConnected != isHostConnected
            let retryRequested = lastRetryGeneration != retryGeneration
            lastIsHostConnected = isHostConnected
            lastRetryGeneration = retryGeneration

            guard connectionChanged || retryRequested else { return }
            guard isHostConnected else {
                prepareForReconnect()
                return
            }

            restartStreaming()
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
            terminalView.onRawInput = nil
            terminalView.onInput = nil
            terminalView.onImagePaste = nil
            terminalView.onFileDrop = nil
            terminalView.onOpenURL = nil

            keystrokeDebouncer?.cancelAll()
            keystrokeDebouncer = nil
            keyCoalescer.reset()
            feedCoalescer.discardPending()

            streamTask?.cancel()
            streamTask = nil
            streamAttemptId = nil
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            terminalView.lockedDimensions = nil

            // Unsubscribe from terminal stream
            if let subscriptionId = streamSubscriptionId {
                connection?.unsubscribeFromTerminalStream(subscriptionId)
                streamSubscriptionId = nil
            }

            // Tell the host to stop streaming this pane only if this view made
            // a request that may still own a host-side subscription.
            if
                recoveryPolicy.hasRequestedStream,
                let leaseId = activeLeaseId,
                let connection,
                connection.isHostConnected,
                let paneId {
                let relayClient = connection.relayClient
                let id = paneId
                Task {
                    _ = await relayClient.sendCommand(
                        StopTerminalStream(leaseId: leaseId),
                        paneId: id
                    )
                }
            }
            activeLeaseId = nil
        }

        // MARK: - Stream Lifecycle

        private func restartStreaming() {
            streamTask?.cancel()
            streamTask = Task { [weak self] in
                await self?.startStreaming()
            }
        }

        private func startStreaming() async {
            guard let connection, let paneId else { return }
            var startMode = recoveryPolicy.nextStartMode()

            // A single retry covers a command response lost during a healthy
            // reconnect. The relay client owns long-lived WebSocket backoff.
            for attempt in 0..<2 {
                guard !Task.isCancelled, connection.isHostConnected else {
                    prepareForReconnect()
                    return
                }

                let previousLeaseId = activeLeaseId
                let leaseId = UUID()
                let attemptId = beginStreamAttempt(leaseId: leaseId)

                if startMode == .replaceExisting, let previousLeaseId {
                    _ = await connection.relayClient.sendCommand(
                        StopTerminalStream(leaseId: previousLeaseId),
                        paneId: paneId,
                    )

                    guard
                        !Task.isCancelled,
                        connection.isHostConnected,
                        streamAttemptId == attemptId
                    else {
                        prepareForReconnect()
                        return
                    }
                }

                bootstrapPolicy.willSendStartRequest()

                let result = await connection.relayClient.sendCommand(
                    StartTerminalStream(leaseId: leaseId),
                    paneId: paneId,
                )

                guard streamAttemptId == attemptId else { return }

                switch result {
                case .success:
                    // A Stage 16 host sends every bootstrap byte before this
                    // response. Older hosts still preserve initial-before-ack.
                    bootstrapPolicy.receiveStartAcknowledgement()
                    revealTerminalIfReady()
                    return

                case let .failure(error):
                    guard !Task.isCancelled, connection.isHostConnected else {
                        prepareForReconnect()
                        return
                    }

                    if attempt == 0 {
                        startMode = .replaceExisting
                        do {
                            try await Task.sleep(for: .milliseconds(500))
                        } catch {
                            return
                        }
                        continue
                    }

                    bootstrapBuffer.reset()
                    updateState(.error(error.localizedDescription))
                }
            }
        }

        private func beginStreamAttempt(leaseId: UUID) -> UUID {
            keystrokeDebouncer?.cancelAll()
            keyCoalescer.reset()
            bootstrapPolicy.beginAttempt()
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            feedCoalescer.discardPending()
            terminalView.preserveUserScroll = false
            terminalView.isHidden = true
            terminalView.getTerminal().resetToInitialState()

            let id = UUID()
            streamAttemptId = id
            activeLeaseId = leaseId
            updateState(.connecting)
            return id
        }

        private func prepareForReconnect() {
            streamTask?.cancel()
            streamTask = nil
            streamAttemptId = nil
            bootstrapPolicy.beginAttempt()
            bootstrapBuffer.reset()
            bootstrapAccumulator.cancel()
            cancelPendingReset()
            feedCoalescer.discardPending()
            terminalView.preserveUserScroll = false
            terminalView.isHidden = true
            keystrokeDebouncer?.cancelAll()
            keyCoalescer.reset()
            updateState(.connecting)
        }

        // MARK: - Key Sends

        /// SwiftTerm's synchronous Meta/Option callbacks have already been
        /// coalesced for this runloop turn. Queue the complete batch immediately
        /// instead of competing with terminal rendering on a 10 ms timer.
        private func enqueueKeySend(keys: [TmuxKey]) {
            guard
                streamState == .streaming,
                let paneId,
                let connection,
                connection.isHostConnected
            else { return }
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: connection.relayClient)
            }
            keystrokeDebouncer?.enqueueImmediately(keys)
        }

        /// Forwards raw bytes (mouse escape sequences) to the host via the relay.
        private func enqueueRawInput(data: Data, connection: ViewerConnection) {
            guard let paneId else { return }
            if keystrokeDebouncer == nil {
                keystrokeDebouncer = KeystrokeDebouncer(paneId: paneId, relayClient: connection.relayClient)
            }
            keystrokeDebouncer?.enqueueRawInput(data)
        }

        // MARK: - Stream Message Handling

        private func handleStreamMessage(_ message: TerminalStreamMessage) {
            switch message.updateType {
            case let .initialState(state):
                guard let data = Data(base64Encoded: state.contentBase64) else { return }
                let expectedByteCount = validSnapshotByteCount(
                    state.contentByteCount,
                    initialContent: data
                )
                guard bootstrapPolicy.receiveInitialState(
                    snapshotIsComplete: expectedByteCount == nil
                ) else { return }

                columns = state.width
                rows = state.height
                updateScrollbackLineLimit(
                    state.scrollbackLineLimit ?? TerminalScrollbackPolicy.defaultLineLimit
                )
                bootstrapBuffer.appendDimensions(cols: columns, rows: rows)
                if let expectedByteCount {
                    beginBootstrapSnapshot(
                        expectedByteCount: expectedByteCount,
                        initialContent: data
                    )
                } else {
                    bootstrapBuffer.appendData(data)
                }

                revealTerminalIfReady()

            case let .resetState(state):
                guard let data = Data(base64Encoded: state.contentBase64) else { return }
                if streamState == .streaming {
                    if !beginAtomicReset(state, initialContent: data) {
                        applyReset(state, content: data)
                    }
                    break
                }
                guard bootstrapPolicy.hasInitialState else { return }

                bootstrapBuffer.reset()
                columns = state.width
                rows = state.height
                updateScrollbackLineLimit(
                    state.scrollbackLineLimit ?? TerminalScrollbackPolicy.defaultLineLimit
                )
                bootstrapBuffer.appendDimensions(cols: columns, rows: rows)
                if let expectedByteCount = validSnapshotByteCount(
                    state.contentByteCount,
                    initialContent: data
                ) {
                    bootstrapPolicy.expectSnapshotCompletion()
                    beginBootstrapSnapshot(
                        expectedByteCount: expectedByteCount,
                        initialContent: data
                    )
                } else {
                    bootstrapAccumulator.cancel()
                    bootstrapPolicy.receiveSnapshotCompletion()
                    bootstrapBuffer.appendData(data)
                }
                revealTerminalIfReady()

            case let .dataChunk(chunk):
                guard bootstrapPolicy.hasInitialState else { return }
                if let data = Data(base64Encoded: chunk.dataBase64) {
                    if bootstrapAccumulator.isCollecting {
                        if let completion = bootstrapAccumulator.append(data) {
                            completeBootstrapSnapshot(completion)
                        }
                        return
                    }
                    if pendingResetState != nil {
                        if let completion = resetAccumulator.append(data) {
                            completeAtomicReset(completion)
                        }
                        return
                    }
                    if streamState == .streaming {
                        feedCoalescer.enqueue(data)
                    } else {
                        bootstrapBuffer.appendData(data)
                    }
                }

            case let .dimensionChange(change):
                guard bootstrapPolicy.hasInitialState else { return }
                columns = change.width
                rows = change.height
                if streamState == .streaming {
                    applyTerminalDimensions(cols: columns, rows: rows)
                    notifyStateChange()
                } else {
                    bootstrapBuffer.appendDimensions(cols: columns, rows: rows)
                }

            case let .titleChange(change):
                onTitleChange?(change.title)

            case .notification:
                // Terminal notifications are handled globally by PaneStreamManager
                break

            case let .clipboardUpdate(update):
                applyClipboardIfFocused(update.content)

            case .streamEnd:
                // A stop sent while replacing our stale subscription can end
                // the old host stream before the matching start arrives.
                guard streamState == .streaming else { return }
                cancelPendingReset()
                updateState(.disconnected)
            }
        }

        private func validSnapshotByteCount(
            _ advertisedByteCount: Int?,
            initialContent: Data
        ) -> Int? {
            guard
                let advertisedByteCount,
                advertisedByteCount >= initialContent.count
            else { return nil }
            return advertisedByteCount
        }

        private func beginBootstrapSnapshot(
            expectedByteCount: Int,
            initialContent: Data
        ) {
            if let completion = bootstrapAccumulator.begin(expectedByteCount: expectedByteCount) {
                completeBootstrapSnapshot(completion)
            } else if
                !initialContent.isEmpty,
                let completion = bootstrapAccumulator.append(initialContent) {
                completeBootstrapSnapshot(completion)
            }
        }

        private func completeBootstrapSnapshot(
            _ completion: TerminalStreamSnapshotAccumulator.Completion
        ) {
            bootstrapBuffer.appendData(completion.content)
            bootstrapBuffer.appendData(completion.remainder)
            bootstrapPolicy.receiveSnapshotCompletion()
            revealTerminalIfReady()
        }

        private func beginAtomicReset(
            _ state: TerminalStreamMessage.InitialState,
            initialContent: Data
        ) -> Bool {
            guard
                let expectedByteCount = validSnapshotByteCount(
                    state.contentByteCount,
                    initialContent: initialContent
                )
            else {
                cancelPendingReset()
                return false
            }

            pendingResetState = state
            if let completion = resetAccumulator.begin(expectedByteCount: expectedByteCount) {
                completeAtomicReset(completion)
            } else if
                !initialContent.isEmpty,
                let completion = resetAccumulator.append(initialContent) {
                completeAtomicReset(completion)
            }
            return true
        }

        private func completeAtomicReset(
            _ completion: TerminalStreamSnapshotAccumulator.Completion
        ) {
            guard let state = pendingResetState else { return }
            pendingResetState = nil
            applyReset(state, content: completion.content)
            if !completion.remainder.isEmpty {
                feedCoalescer.enqueue(completion.remainder)
            }
        }

        private func applyReset(
            _ state: TerminalStreamMessage.InitialState,
            content: Data
        ) {
            columns = state.width
            rows = state.height
            updateScrollbackLineLimit(
                state.scrollbackLineLimit ?? TerminalScrollbackPolicy.defaultLineLimit
            )
            applyTerminalDimensions(cols: columns, rows: rows)
            feedCoalescer.replace(with: content) { [terminalView] in
                terminalView.getTerminal().resetToInitialState()
                terminalView.preserveUserScroll = false
            }
            terminalView.scroll(toPosition: 1)
            terminalView.preserveUserScroll = true
            terminalView.isHidden = false
            terminalView.needsDisplay = true
            notifyStateChange()
        }

        private func cancelPendingReset() {
            pendingResetState = nil
            resetAccumulator.cancel()
        }

        private func revealTerminalIfReady() {
            guard bootstrapPolicy.isReady, streamState != .streaming else { return }

            var replacedTerminal = false
            for event in bootstrapBuffer.takeEvents() {
                switch event {
                case let .dimensions(cols, rows):
                    applyTerminalDimensions(cols: cols, rows: rows)
                case let .data(data):
                    if replacedTerminal {
                        feedCoalescer.enqueue(data)
                    } else {
                        feedCoalescer.replace(with: data) { [terminalView] in
                            terminalView.getTerminal().resetToInitialState()
                        }
                        replacedTerminal = true
                    }
                }
            }
            feedCoalescer.flushPendingNow()

            terminalView.scroll(toPosition: 1)
            terminalView.preserveUserScroll = true
            terminalView.isHidden = false
            terminalView.needsDisplay = true
            updateState(.streaming)

            if terminalView.autoFocusEnabled, !terminalView.isEditorActive {
                terminalView.focusTerminal()
            }
        }

        // MARK: - Clipboard

        /// Sets the system clipboard if this terminal's window is the key window
        /// and the app is active.
        private func applyClipboardIfFocused(_ content: String) {
            guard NSApp.isActive else { return }
            // Check if the terminal view's window is key
            guard terminalView.window?.isKeyWindow == true else { return }
            clipboard.setString(content)
        }

        // MARK: - Settings

        func updateSettings(_ settings: AppSettings) {
            updateFont(name: settings.fontName, size: CGFloat(settings.fontSize))
            terminalView.applyTheme(settings.theme)
            terminalView.autoCopyOnSelect = settings.autoCopyOnSelect
        }

        private func updateScrollbackLineLimit(_ requested: Int) {
            let lineLimit = TerminalScrollbackPolicy.normalizedLineLimit(requested)
            guard lineLimit != scrollbackLineLimit else { return }
            scrollbackLineLimit = lineLimit
            terminalView.changeScrollback(lineLimit)
        }

        func updateContainerSize(_ size: NSSize) {
            guard size != containerSize else { return }
            containerSize = size
        }

        private func updateFont(name: String, size: CGFloat) {
            guard name != fontName || size != fontSize else { return }
            fontName = name
            fontSize = size

            let font = NSFont(name: name, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            terminalView.font = font
            updateTerminalFrameSize()
        }

        // MARK: - Private Helpers

        private func updateTerminalFrameSize() {
            let optimalSize = terminalView.getOptimalFrameSize().size
            terminalView.setTerminalSize(optimalSize)
        }

        private func applyTerminalDimensions(cols: Int, rows: Int) {
            columns = cols
            self.rows = rows
            terminalView.lockedDimensions = (cols: cols, rows: rows)
            terminalView.getTerminal().resize(cols: cols, rows: rows)
            updateTerminalFrameSize()
        }

        private func updateState(_ state: RemoteStreamState) {
            streamState = state
            quickActionEndpoint?.isReady = state == .streaming
            notifyStateChange()
        }

        private func notifyStateChange() {
            onStateChange?(streamState, columns, rows)
        }
    }
}
