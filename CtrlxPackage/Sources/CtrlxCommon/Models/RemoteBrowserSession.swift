import CtrlxNetworking
import Dependencies
import Foundation
import Observation

/// One visible Viewer surface: at most one frame and one ordered input request.
@MainActor @Observable
final public class RemoteBrowserSession {
    public private(set) var tab: RemoteBrowserTab
    public private(set) var frame: RemoteBrowserFrame?
    public private(set) var controlID: UUID?
    public private(set) var error: String?
    public private(set) var frameError: String?
    public private(set) var isTakingControl = false
    public var supportsClipboard = true
    public private(set) var clipboardMessage: String?
    public private(set) var audioEnabled = true
    public private(set) var isAudioActive = false
    public private(set) var supportsAudio = false
    public private(set) var audioError: String?
    @ObservationIgnored @Dependency(BrowserAudioOutputClient.self) private var audioOutput
    @ObservationIgnored private var audioStreamID: UUID?
    @ObservationIgnored private var audioRevision: UInt64 = 0
    @ObservationIgnored private var audioSequence: UInt64 = 0
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var registerAudio: @MainActor (UUID, @escaping @MainActor @Sendable (RemoteBrowserAudio) -> Void) -> Void = { _, _ in }
    @ObservationIgnored private var unregisterAudio: @MainActor (UUID) -> Void = { _ in }
    @ObservationIgnored @Dependency(ClipboardClient.self) private var clipboard
    public let managesExtensions: Bool
    public private(set) var openedStoreTab: RemoteBrowserTab?
    public private(set) var extensionSurface: RemoteBrowserExtensionSurface = .manager
    @ObservationIgnored private let anchorTabID: UUID
    @ObservationIgnored private let surfaceID = UUID()
    @ObservationIgnored private let supportsStalePointerCleanup: @MainActor () -> Bool
    @ObservationIgnored private let send: @MainActor (BrowseBrowser) async throws -> RemoteBrowserResponse
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var inputs: [(RemoteBrowserOperation, UInt64)] = []
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputEpoch = UUID()
    @ObservationIgnored private var pendingRelease: Task<Void, Never>?
    @ObservationIgnored public var frameMaxDimension: Int?

    public init(
        tab: RemoteBrowserTab,
        managesExtensions: Bool = false,
        supportsStalePointerCleanup: @escaping @MainActor () -> Bool = { false },
        send: @escaping @MainActor (BrowseBrowser) async throws -> RemoteBrowserResponse
    ) {
        self.tab = tab
        self.anchorTabID = tab.id
        self.managesExtensions = managesExtensions
        self.supportsStalePointerCleanup = supportsStalePointerCleanup
        self.send = send
    }

    public convenience init(tab: RemoteBrowserTab, client: ViewerRelayClient, managesExtensions: Bool = false) {
        self.init(
            tab: tab,
            managesExtensions: managesExtensions,
            supportsStalePointerCleanup: { [weak client] in
                client?.hostSupportsBrowserStalePointerCleanup == true
            }
        ) { request in
            let timeout: TimeInterval
            switch request.operation {
            case .extensions(.prepareStore),
                 .extensions(.install),
                 .extensions(.remove),
                 .extensions(.setEnabled): timeout = 120
            default: timeout = 8
            }
            let result = try await client.sendCommand(request, paneId: "", timeout: timeout).get()
            guard result.success, let response = result.browser else {
                throw ViewerRelayClientError.commandFailed(result.error ?? "Missing browser response")
            }
            return response
        }
        self.supportsClipboard = client.hostSupportsWorkspaceClipboard && !managesExtensions
        self.supportsAudio = client.hostSupportsBrowserAudio && !managesExtensions
        self.registerAudio = { [weak client] id, handler in client?.registerBrowserAudio(id, handler: handler) }
        self.unregisterAudio = { [weak client] id in client?.unregisterBrowserAudio(id) }
    }

    private func request(_ operation: RemoteBrowserOperation, generation: UInt64? = nil) -> BrowseBrowser {
        BrowseBrowser(
            sessionName: tab.sessionName,
            tabID: anchorTabID,
            surfaceID: surfaceID,
            controlID: controlID,
            generation: generation ?? frame?.generation,
            frameMaxDimension: operation == .frame ? frameMaxDimension : nil,
            operation: scoped(operation)
        )
    }

    private func scoped(_ operation: RemoteBrowserOperation) -> RemoteBrowserOperation {
        guard managesExtensions else { return operation }
        switch operation {
        case .frame: return .extensions(.frame)
        case .takeControl: return .extensions(.acquire)
        case .releaseControl: return .extensions(.release)
        case let .text(text): return .extensions(.text(text))
        case let .key(key): return .extensions(.key(key))
        case let .pointer(pointer): return .extensions(.pointer(pointer))
        case let .fit(width, height): return .extensions(.fit(width: width, height: height))
        default: return operation
        }
    }

    public func performExtension(_ operation: RemoteBrowserExtensionOperation) async throws -> RemoteBrowserResponse {
        guard managesExtensions, watching, let controlID else {
            throw ViewerRelayClientError.commandFailed("Take extension control first.")
        }
        let current = epoch
        let result = try await send(request(.extensions(operation)))
        guard watching, epoch == current, self.controlID == controlID, !Task.isCancelled else { throw CancellationError() }
        if let surface = result.extensions?.surface {
            extensionSurface = surface
        }
        try acceptStoreTab(result.extensions?.openedStoreTab)
        switch operation {
        case .openWindow,
             .showSurface,
             .openOptions:
            invalidateInput()
            frame = nil
            frameError = nil
        default: break
        }
        return result
    }

    private func acceptStoreTab(_ opened: RemoteBrowserTab?) throws {
        guard let opened else { return }
        guard
            opened.sessionName == tab.sessionName, opened.sourcePaneID == tab.sourcePaneID,
            opened.sourcePaneID != nil, opened.id != anchorTabID, !opened.isAgentOwned,
            opened.isExtensionWindow != true, BrowserExtensionStoreURL.isStore(opened.url) else {
            throw ViewerRelayClientError.commandFailed("The Host returned a store tab outside the source pane.")
        }
        openedStoreTab = opened
    }

    public func watch() async {
        stop()
        watching = true
        let current = epoch
        var first = true
        defer {
            if epoch == current {
                stop()
            }
        }
        while !Task.isCancelled, watching, epoch == current {
            if managesExtensions && controlID == nil {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                continue
            }
            let sent = request(.frame)
            let sentInputEpoch = inputEpoch
            do {
                let response = try await send(sent)
                try Task.checkCancellation()
                if managesExtensions, epoch == current, sent.controlID != controlID {
                    continue
                }
                if managesExtensions, sentInputEpoch != inputEpoch {
                    continue
                }
                if managesExtensions, epoch == current, response.controlID == nil {
                    error = "Extension control was released on the Host. Take Control again to continue."
                    releaseControl()
                    continue
                }
                guard epoch == current else { return }
                try acceptStoreTab(response.extensions?.openedStoreTab)
                if openedStoreTab != nil {
                    return
                }
                guard let frame = response.frame, frame.isValid else { return }
                if self.frame != frame {
                    self.frame = frame
                }
                frameError = nil
                if let tab = response.tab {
                    self.tab = tab
                }
                if let surface = response.extensions?.surface {
                    extensionSurface = surface
                }
                if controlID == sent.controlID, controlID != response.controlID {
                    invalidateInput()
                    stopAudio()
                    controlID = response.controlID
                }
                if first, !managesExtensions, !tab.isAgentOwned, tab.grant == nil, !tab.isControlled, tab.isExtensionWindow != true {
                    await takeControl()
                }
                first = false
            } catch is CancellationError { return }
            catch {
                if epoch == current, !managesExtensions || sentInputEpoch == inputEpoch {
                    frameError = error.localizedDescription
                }
            }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
    }

    public func stop() {
        watching = false
        epoch = UUID()
        releaseControl()
        frame = nil
    }

    public func prepareExtensionPackage(file url: URL, replacingID: String?, progress: (Double) -> Void) async throws -> RemoteBrowserExtensionPreview {
        guard managesExtensions, let grant = controlID else { throw ViewerRelayClientError.commandFailed("Take extension control first.") }
        @Dependency(FileBrowserUploadReader.self) var reader
        let file = try await reader.open(url)
        do {
            guard
                controlID == grant, file.size > 0, file.size <= 64 * 1_024 * 1_024,
                ["zip", "crx"].contains(url.pathExtension.lowercased()) else {
                throw ViewerRelayClientError.commandFailed("Choose a ZIP or CRX3 package up to 64 MiB while extension control is active.")
            }
            _ = try await performExtension(.beginUpload(id: file.id, name: file.name, size: file.size, replacingID: replacingID))
            var offset = 0
            while offset < file.size {
                try Task.checkCancellation()
                let data = try await reader.read(file.id)
                guard controlID == grant, !data.isEmpty else { throw CancellationError() }
                let response = try await performExtension(.appendUpload(id: file.id, offset: offset, data: data))
                offset += data.count
                guard response.extensions?.uploadOffset == offset else { throw ViewerRelayClientError.commandFailed("The Host did not acknowledge the complete package chunk.") }
                progress(Double(offset) / Double(file.size))
            }
            let checksum = try await reader.finish(file.id)
            guard controlID == grant else { throw CancellationError() }
            let response = try await performExtension(.finishUpload(id: file.id, sha256: checksum))
            guard let preview = response.extensions?.prepared else { throw ViewerRelayClientError.commandFailed("The Host did not return package permissions.") }
            await reader.close(file.id)
            return preview
        } catch {
            // Best effort: disconnect/expiry also removes the private Host upload.
            if controlID == grant {
                _ = try? await performExtension(.cancelUpload(file.id))
            }
            await reader.close(file.id)
            throw error
        }
    }

    public func takeControl(opensExtensionWindow: Bool = false) async {
        guard watching, !isTakingControl, controlID == nil else { return }
        isTakingControl = true
        defer { isTakingControl = false }
        let current = epoch
        let pending = pendingRelease
        pendingRelease = nil
        await pending?.value
        guard watching, epoch == current, !Task.isCancelled, controlID == nil else { return }
        do {
            let result = try await send(request(.takeControl))
            guard watching, epoch == current, !Task.isCancelled else {
                if let id = result.controlID {
                    release(id)
                }
                return
            }
            controlID = result.controlID
            if let tab = result.tab {
                self.tab = tab
            }
            error = nil
            configureAudio()
            if managesExtensions, controlID != nil {
                _ = try await performExtension(
                    tab.isExtensionWindow == true || opensExtensionWindow ? .openWindow : .showSurface(.manager)
                )
            }
        } catch {
            if epoch == current {
                self.error = error.localizedDescription
                if managesExtensions {
                    releaseControl()
                }
            }
        }
    }

    public func releaseControl() {
        stopAudio()
        invalidateInput()
        if let id = controlID {
            release(id)
        }
        controlID = nil
        if managesExtensions {
            frame = nil
        }
    }

    public func setAudioEnabled(_ enabled: Bool) {
        guard audioEnabled != enabled else { return }
        audioEnabled = enabled
        configureAudio()
    }

    public func setAudioSupport(_ supported: Bool) {
        let supported = supported && !managesExtensions
        guard supportsAudio != supported else { return }
        supportsAudio = supported
        configureAudio()
    }

    private func stopAudio() {
        audioTask?.cancel()
        audioTask = nil
        if let id = audioStreamID {
            unregisterAudio(id)
            audioOutput.stop(id)
        }
        audioStreamID = nil
        audioSequence = 0
        isAudioActive = false
    }

    private func configureAudio(active: Bool = true) {
        stopAudio()
        guard watching, supportsAudio, let grant = controlID, !managesExtensions else { return }
        audioError = nil
        let id = UUID()
        audioStreamID = id
        audioRevision += 1
        let enabled = audioEnabled && active
        let message = request(.audio(streamID: id, revision: audioRevision, enabled: enabled))
        registerAudio(id) { [weak self] packet in self?.receiveAudio(packet) }
        if active {
            do {
                try audioOutput.start(id) { [weak self] error in
                    guard let self, self.audioStreamID == id else { return }
                    if error == nil {
                        self.configureAudio(active: false)
                    } else {
                        self.setAudioEnabled(false)
                    }
                    self.audioError = error
                }
                isAudioActive = true
            } catch {
                audioError = error.localizedDescription
                audioEnabled = false
                configureAudio()
                audioError = error.localizedDescription
                return
            }
        }
        audioTask = Task { [weak self, send] in
            do {
                let response = try await send(message)
                guard let self, self.audioStreamID == id, self.controlID == grant, !Task.isCancelled else { return }
                guard response.controlID == grant else {
                    self.releaseControl()
                    return
                }
            } catch {
                guard !Task.isCancelled, let self, self.audioStreamID == id else { return }
                self.stopAudio()
                self.audioEnabled = false
                self.audioError = error.localizedDescription
            }
        }
    }

    func receiveAudio(_ packet: RemoteBrowserAudio) {
        guard
            watching, audioEnabled, packet.isValid, packet.tabID == anchorTabID,
            packet.surfaceID == surfaceID, packet.controlID == controlID, packet.streamID == audioStreamID,
            packet.sequence > audioSequence else { return }
        audioSequence = packet.sequence
        if let error = packet.error {
            setAudioEnabled(false)
            audioError = error
        } else {
            audioOutput.receive(packet.streamID, packet)
        }
    }

    private func invalidateInput() {
        clipboardMessage = nil
        inputEpoch = UUID()
        inputs.removeAll()
        inputTask?.cancel()
        inputTask = nil
    }

    private func release(_ id: UUID) {
        let message = BrowseBrowser(
            sessionName: tab.sessionName,
            tabID: anchorTabID,
            surfaceID: surfaceID,
            controlID: id,
            operation: scoped(.releaseControl)
        )
        // Best effort on disappearance. Host also releases on disconnect/expiry.
        pendingRelease = Task { [send] in _ = try? await send(message) }
    }

    public func dismissError() {
        error = nil
        frameError = nil
        audioError = nil
    }

    public func respondToNetworkPermission(_ id: UUID, allow: Bool) async throws {
        guard watching, let controlID, !managesExtensions, tab.networkPermission?.id == id else {
            throw ViewerRelayClientError.commandFailed("Take Control of the page before responding to this permission request.")
        }
        let current = epoch
        let response = try await send(request(.networkPermission(id: id, allow: allow)))
        guard watching, epoch == current, self.controlID == controlID, response.controlID == controlID else {
            throw ViewerRelayClientError.commandFailed("Browser control changed.")
        }
        if let tab = response.tab {
            self.tab = tab
        }
    }

    public func copy() {
        guard supportsClipboard else { error = "Update the Host Mac to copy from this page."
            return
        }
        clipboardMessage = nil
        submit(.copy)
    }

    public func paste() {
        clipboardMessage = nil
        do {
            if supportsClipboard {
                try submit(.paste(clipboard.workspaceContent()))
            } else if let text = clipboard.getString() {
                submit(.text(text))
            }
        } catch { self.error = error.localizedDescription }
    }

    public func submit(_ operation: RemoteBrowserOperation) {
        guard let frame else { return }
        submit(operation, generation: frame.generation)
    }

    public func submit(_ operation: RemoteBrowserOperation, generation: UInt64) {
        guard watching, let controlID else { return }
        let activatesAudio = switch operation {
        case let .pointer(pointer): pointer.kind == .down || pointer.kind == .scroll
        default: true
        }
        if activatesAudio, supportsAudio, !isAudioActive {
            configureAudio()
        }
        if
            case let .pointer(new) = operation, new.kind == .move,
            let last = inputs.last, last.1 == generation, case let .pointer(old) = last.0, old.kind == .move {
            inputs[inputs.count - 1] = (operation, generation)
        } else if
            case let .pointer(new) = operation, new.kind == .scroll,
            let last = inputs.last, last.1 == generation,
            case let .pointer(old) = last.0, old.kind == .scroll, old.modifiers == new.modifiers {
            inputs[inputs.count - 1] = (.pointer(.init(
                .scroll,
                x: new.x,
                y: new.y,
                modifiers: new.modifiers,
                deltaX: max(-4_096, min(4_096, old.deltaX + new.deltaX)),
                deltaY: max(-4_096, min(4_096, old.deltaY + new.deltaY))
            )), generation)
        } else {
            guard inputs.count < 32 else {
                error = "Connection is too slow for more input. Control was released; no input will be replayed."
                releaseControl()
                return
            }
            inputs.append((operation, generation))
        }
        guard inputTask == nil else { return }
        let current = epoch
        let inputGeneration = inputEpoch
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.inputEpoch == inputGeneration {
                    self.inputTask = nil
                }
            }
            while
                !Task.isCancelled, self.epoch == current, self.inputEpoch == inputGeneration,
                self.controlID == controlID, !self.inputs.isEmpty {
                let (operation, generation) = self.inputs.removeFirst()
                do {
                    let response = try await self.send(self.request(operation, generation: generation))
                    guard
                        !Task.isCancelled, self.epoch == current, self.inputEpoch == inputGeneration,
                        self.controlID == controlID else { return }
                    if operation == .copy || operation.isClipboardPaste {
                        guard response.controlID == controlID else { throw WorkspaceClipboardError.message("Browser control changed before clipboard transfer completed.") }
                    }
                    if operation == .copy {
                        guard let content = response.clipboard else {
                            throw WorkspaceClipboardError.message("The Host returned no copied content.")
                        }
                        try self.clipboard.setWorkspaceContent(content)
                        self.clipboardMessage = "Copied."
                    } else if operation.isClipboardPaste {
                        self.clipboardMessage = "Paste sent."
                    }
                } catch {
                    guard
                        !Task.isCancelled, self.epoch == current,
                        self.inputEpoch == inputGeneration, self.controlID == controlID else { return }
                    if
                        case let ViewerRelayClientError.commandFailed(message) = error,
                        message == "Page changed. Read a new frame before interacting.",
                        self.supportsStalePointerCleanup() {
                        // Navigation can advance the Host generation between a
                        // pointer down and up. New Hosts end the stale pointer
                        // before replying, so the lease remains valid. Older
                        // Hosts leave it pressed; release control to clean up.
                        self.inputs.removeAll()
                        return
                    }
                    self.error = error.localizedDescription
                    self.inputs.removeAll()
                    self.releaseControl()
                    return
                }
            }
        }
    }

    public static func open(sessionName: String, sourcePaneID: String, url: URL? = nil, client: ViewerRelayClient) async throws -> RemoteBrowserTab {
        let destination = url ?? BrowserWebURL.homepage
        let request = BrowseBrowser(sessionName: sessionName, surfaceID: UUID(), operation: .openPane(url: destination.absoluteString), sourcePaneID: sourcePaneID)
        let result = try await client.sendCommand(request, paneId: "", timeout: 10).get()
        guard let tab = result.browser?.tab, tab.sourcePaneID == sourcePaneID, tab.sessionName == sessionName else {
            throw ViewerRelayClientError.commandFailed("Host did not return the source pane's browser tab")
        }
        client.rememberOpenedBrowser(tab)
        _ = await client.requestSessionState()
        return tab
    }

    public static func close(tab: RemoteBrowserTab, client: ViewerRelayClient) async throws {
        let session = RemoteBrowserSession(tab: tab, client: client)
        _ = try await session.send(session.request(.close))
        _ = await client.requestSessionState()
    }
}
