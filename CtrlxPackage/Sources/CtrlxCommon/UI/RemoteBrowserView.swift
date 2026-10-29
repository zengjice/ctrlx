#if os(macOS) || os(iOS)
    import CtrlxNetworking
    import Dependencies
    import ImageIO
    import SwiftUI

    @MainActor
    public struct RemoteBrowserView: View {
        @State private var session: RemoteBrowserSession
        @State private var address = ""
        @State private var image: CGImage?
        @State private var displayedFrame: RemoteBrowserFrame?
        @State private var viewport = CGSize.zero
        @State private var keyboardRequested = false
        @State private var inputFocusRequest: UUID?
        @State private var isAnnotating = false
        @State private var captureRequest: UUID?
        @AppStorage("browserAudioEnabled") private var audioEnabled = true
        private struct ExtensionRequest: Identifiable {
            let id = UUID()
            let storeID: String?
            var initialView: RemoteBrowserExtensionInitialView = .manager
        }

        @State private var extensionRequest: ExtensionRequest?
        private let onOpenBrowser: (RemoteBrowserTab) -> Void
        @FocusState private var editingAddress: Bool
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.displayScale) private var displayScale
        @Environment(\.browserAnnotationContext) private var annotationContext
        private let client: ViewerRelayClient

        public init(tab: RemoteBrowserTab, client: ViewerRelayClient, onOpenBrowser: @escaping (RemoteBrowserTab) -> Void) {
            self.client = client
            self.onOpenBrowser = onOpenBrowser
            _session = State(initialValue: RemoteBrowserSession(tab: tab, client: client))
        }

        public var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { session.submit(.back) } label: { Label("Back", symbol: .chevronLeft) }
                        Button { session.submit(.forward) } label: { Label("Forward", symbol: .chevronRight) }
                        Button { session.submit(.reload) } label: { Label("Reload", symbol: .arrowClockwise) }
                        TextField("Search Google or enter address", text: $address)
                            .focused($editingAddress)
                            .onSubmit(navigate)
                            .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        #endif
                        Button {
                            session.submit(.fit(
                                width: Int(max(240, min(viewport.width, 2_560))),
                                height: Int(max(240, min(viewport.height, 2_560)))
                            ))
                        } label: { Label("Fit to This Device", symbol: .arrowUpLeftAndArrowDownRight) }
                            .help("Changes the page viewport on the Host and all Viewers")
                    }
                    .disabled(session.controlID == nil)
                    if client.hostSupportsBrowserBookmarks {
                        BrowserBookmarksButton(
                            url: session.tab.url,
                            navigationUnavailableReason: session.controlID == nil ? "Take Control to open a bookmark." : nil,
                            request: bookmarkRequest,
                            navigate: { url in
                                guard session.controlID != nil else { return }
                                session.submit(.navigate(url))
                                editingAddress = false
                                inputFocusRequest = UUID()
                            }
                        )
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(isAnnotating)
                .padding(8)
                HStack {
                    Label("Host · Chromium", symbol: .globe).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if client.hostSupportsResourceAuthorization, let sessionID = session.tab.resourceSessionID {
                        ResourceAgentMenu(kind: .browser, tabID: session.tab.id, sessionID: sessionID, grant: session.tab.grant) {
                            try await ResourceTabClient.request($0, client: client)
                        }
                    }
                    if client.hostSupportsBrowserAudio, session.tab.isExtensionWindow != true {
                        Button {
                            audioEnabled = !session.audioEnabled
                            session.setAudioEnabled(audioEnabled)
                        } label: {
                            Label(
                                session.audioEnabled ? "Mute Page Sound" : "Enable Page Sound",
                                symbol: session.audioEnabled ? .speakerWave2Fill : .speakerSlashFill
                            ).labelStyle(.iconOnly)
                        }
                        .disabled(session.controlID == nil)
                        .help(session.controlID == nil ? "Take Control to receive page sound" : "Play this page's sound on this device")
                        .accessibilityIdentifier("remote-browser-audio")
                    }
                    if client.hostSupportsBrowserExtensions {
                        if session.tab.isExtensionWindow != true {
                            #if os(macOS)
                                Button {
                                    session.releaseControl()
                                    extensionRequest = ExtensionRequest(storeID: nil, initialView: .window)
                                } label: { Label("Open Page as Chrome Window", symbol: .arrowUpRightSquare).labelStyle(.iconOnly) }
                                    .accessibilityIdentifier("remote-browser-extension-window")
                            #endif
                        }
                        Button {
                            session.releaseControl()
                            extensionRequest = ExtensionRequest(storeID: nil)
                        } label: { Label("Browser Extensions", symbol: .puzzlepiece).labelStyle(.iconOnly) }
                            .accessibilityIdentifier("remote-browser-extensions")
                    }
                    if session.controlID != nil {
                        if session.supportsClipboard {
                            Button(action: session.copy) { Label("Copy", symbol: .docOnDoc).labelStyle(.iconOnly) }
                        }
                        Button(action: session.paste) { Label("Paste", symbol: .docOnClipboard).labelStyle(.iconOnly) }
                    }
                    #if os(iOS)
                        if session.tab.isExtensionWindow != true {
                            Button(action: requestKeyboard) {
                                Label("Keyboard", symbol: .keyboard).labelStyle(.iconOnly)
                            }
                            .disabled(!client.isHostConnected || session.frame == nil || session.isTakingControl)
                            .accessibilityHint(session.controlID == nil
                                ? "Take control and show the keyboard."
                                : "Show or hide the keyboard.")
                            .accessibilityIdentifier("remote-browser-keyboard")
                        }
                    #endif
                    if session.controlID != nil {
                        RemoteControlButton(
                            title: session.tab.isAgentOwned ? "Return to Agent" : "Release Control",
                            isControlled: true
                        ) {
                            keyboardRequested = false
                            session.releaseControl()
                        }
                    } else if session.tab.isExtensionWindow != true {
                        RemoteControlButton(
                            title: "Take Control",
                            isControlled: false,
                            isDisabled: session.isTakingControl || !client.isHostConnected || session.frame == nil
                        ) {
                            takeControl()
                        }
                    }
                    if session.tab.isExtensionWindow != true {
                        Button { captureRequest = UUID() } label: {
                            Label("Annotate Screenshot", symbol: .pencilLine).labelStyle(.iconOnly)
                        }
                        .disabled(annotationContext?.isAvailable != true)
                        .help("Mark this page and add it to an Agent input")
                        .accessibilityIdentifier("remote-browser-annotate")
                    }
                }.disabled(isAnnotating).padding(.horizontal, 8).padding(.bottom, 8)
                if client.hostSupportsBrowserExtensions, let id = BrowserExtensionStoreURL.extensionID(from: session.tab.url) {
                    HStack {
                        Text("Chrome Web Store").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Install on Host") {
                            session.releaseControl()
                            extensionRequest = ExtensionRequest(storeID: id)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("browser-install-store-extension")
                    }.disabled(isAnnotating).padding(.horizontal, 8).padding(.bottom, 8)
                }
                Divider()
                BrowserNetworkPermissionBanner(permission: session.tab.networkPermission, canRespond: session.controlID != nil) { id, allow in
                    try await session.respondToNetworkPermission(id, allow: allow)
                }
                BrowserAnnotationSurface(
                    preferredTarget: session.tab.sourceAgent,
                    requiresRecipientSelection: session.tab.sourceAgent == nil,
                    capture: {
                        let request = BrowseBrowser(
                            sessionName: session.tab.sessionName,
                            tabID: session.tab.id,
                            surfaceID: UUID(),
                            frameMaxDimension: RemoteBrowserFrame.maximumDimension,
                            operation: .frame
                        )
                        let result = try await client.sendCommand(request, paneId: "", timeout: 10).get()
                        guard result.success, let frame = result.browser?.frame, frame.isValid else {
                            throw AgentImageError.message(result.error ?? "Could not capture the Host page.")
                        }
                        return frame.jpeg
                    },
                    onEditingChanged: { editing in
                        isAnnotating = editing
                        if editing {
                            keyboardRequested = false
                            editingAddress = false
                            session.releaseControl()
                        }
                    },
                    captureRequest: captureRequest
                ) {
                    RemoteBrowserCanvas(
                        image: image,
                        frame: displayedFrame,
                        acceptsInput: session.controlID != nil && !editingAddress && !isAnnotating,
                        keyboardRequested: keyboardRequested,
                        allowsLocalZoom: session.controlID == nil,
                        zoomIdentity: session.tab.id.uuidString + session.tab.url,
                        focusRequest: inputFocusRequest,
                        onCopy: session.copy,
                        onPaste: session.paste
                    ) { operation in
                        guard !isAnnotating else { return }
                        if let displayedFrame {
                            session.submit(operation, generation: displayedFrame.generation)
                        }
                    }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: {
                        viewport = $0
                        updateFrameResolution()
                    }
                    .overlay {
                        if image == nil {
                            if client.isHostConnected {
                                ProgressView("Connecting to Host page…")
                            } else {
                                Text("Host disconnected").padding()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(WorkspaceClipboardFeedback(message: session.clipboardMessage))
                }
                if let error = session.error ?? session.frameError ?? session.audioError {
                    HStack {
                        Text(error).font(.caption)
                        Spacer()
                        Button { session.dismissError() } label: { Label("Dismiss", symbol: .xmark) }.labelStyle(.iconOnly)
                    }.padding(8)
                }
                BrowserExternalApplicationBanner(notice: session.tab.externalApplicationNotice)
            }
            .task(id: extensionRequest == nil && scenePhase == .active && client.isHostConnected && client.hostSupportsBrowserSharing) {
                guard extensionRequest == nil, scenePhase == .active, client.isHostConnected, client.hostSupportsBrowserSharing else {
                    session.stop()
                    image = nil
                    displayedFrame = nil
                    return
                }
                session.setAudioEnabled(audioEnabled)
                await session.watch()
            }
            .modifier(RemoteBrowserFrameDecoding(
                frame: session.frame,
                isAnnotating: isAnnotating,
                image: $image,
                displayedFrame: $displayedFrame
            ))
            .onChange(of: session.tab.url, initial: true) { _, url in
                if !editingAddress {
                    address = url == "about:blank" ? "" : url
                }
            }
            .onChange(of: session.frame.map { CGSize(width: $0.width, height: $0.height) }) { _, _ in updateFrameResolution() }
            .onChange(of: displayScale) { _, _ in updateFrameResolution() }
            .onChange(of: client.hostSupportsWorkspaceClipboard, initial: true) { _, supported in session.supportsClipboard = supported }
            .onChange(of: client.hostSupportsBrowserAudio, initial: true) { _, supported in session.setAudioSupport(supported) }
            .onDisappear { session.stop() }
            .accessibilityIdentifier("remote-browser-page")
            .sheet(item: $extensionRequest) { request in
                RemoteBrowserExtensionsView(
                    tab: session.tab,
                    client: client,
                    initialStoreID: request.storeID,
                    initialView: request.initialView,
                    onOpenBrowser: onOpenBrowser
                )
            }
        }

        private func bookmarkRequest(_ operation: BrowserBookmarkOperation) async throws -> [BrowserBookmark] {
            let request = BrowseBrowser(
                sessionName: session.tab.sessionName,
                tabID: session.tab.id,
                surfaceID: UUID(),
                operation: .bookmarks(operation)
            )
            let response = try await client.sendCommand(request, paneId: "", timeout: 8).get()
            guard response.success, let bookmarks = response.browser?.bookmarks else {
                throw ViewerRelayClientError.commandFailed(response.error ?? "Could not load Host bookmarks.")
            }
            return bookmarks
        }

        private func navigate() {
            guard let url = BrowserWebURL.navigationURL(from: address) else { return }
            address = url.absoluteString
            session.submit(.navigate(address))
            editingAddress = false
            inputFocusRequest = UUID()
        }

        private func takeControl() {
            editingAddress = false
            Task {
                await session.takeControl()
                if session.controlID != nil {
                    inputFocusRequest = UUID()
                }
            }
        }

        private func requestKeyboard() {
            editingAddress = false
            if session.controlID != nil {
                keyboardRequested.toggle()
                return
            }
            guard !session.isTakingControl, client.isHostConnected, session.frame != nil else { return }
            keyboardRequested = true
            Task {
                await session.takeControl()
                if session.controlID == nil {
                    keyboardRequested = false
                }
            }
        }

        private func updateFrameResolution() {
            let page = session.frame.map { CGSize(width: $0.width, height: $0.height) } ?? viewport
            session.frameMaxDimension = RemoteBrowserGeometry.frameMaxDimension(viewSize: viewport, pageSize: page, displayScale: displayScale)
        }
    }

    /// Keep task identity tied to presentation as well as received frames: polling
    /// may deduplicate the latest frame after annotation ends.
    @MainActor
    struct RemoteBrowserFrameDecoding: ViewModifier {
        let frame: RemoteBrowserFrame?
        let isAnnotating: Bool
        @Binding var image: CGImage?
        @Binding var displayedFrame: RemoteBrowserFrame?

        private struct TaskID: Equatable {
            let frame: RemoteBrowserFrame?
            let isAnnotating: Bool
        }

        func body(content: Content) -> some View {
            content.task(id: TaskID(frame: frame, isAnnotating: isAnnotating)) {
                guard !isAnnotating else { return }
                guard let frame else { image = nil
                    displayedFrame = nil
                    return
                }
                let decoded = await BrowserFrameDecoder.decode(frame.jpeg)
                if !Task.isCancelled {
                    image = decoded
                    displayedFrame = decoded == nil ? nil : frame
                }
            }
        }
    }

    private enum BrowserFrameDecoder {
        @concurrent
        static func decode(_ data: Data) async -> CGImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }

    public enum RemoteBrowserGeometry {
        public static func frameMaxDimension(viewSize: CGSize, pageSize: CGSize, displayScale: CGFloat) -> Int? {
            guard
                viewSize.width.isFinite, viewSize.height.isFinite, pageSize.width.isFinite, pageSize.height.isFinite,
                viewSize.width > 0, viewSize.height > 0, pageSize.width > 0, pageSize.height > 0,
                displayScale.isFinite, displayScale > 0 else { return nil }
            let size = imageRect(viewSize: viewSize, pageSize: pageSize).size
            let pixels = min(CGFloat(RemoteBrowserFrame.maximumDimension), max(size.width, size.height) * displayScale)
            // Buckets avoid creating a new capture size for every point of window resizing.
            return max(256, Int(ceil(pixels / 128)) * 128)
        }

        public static func imageRect(viewSize: CGSize, pageSize: CGSize) -> CGRect {
            guard viewSize.width > 0, viewSize.height > 0, pageSize.width > 0, pageSize.height > 0 else { return .zero }
            let scale = min(viewSize.width / pageSize.width, viewSize.height / pageSize.height)
            let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
            return CGRect(
                x: (viewSize.width - size.width) / 2,
                y: (viewSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        }

        public static func pagePoint(_ point: CGPoint, viewSize: CGSize, pageSize: CGSize, clamped: Bool = false) -> CGPoint? {
            let rect = imageRect(viewSize: viewSize, pageSize: pageSize)
            guard rect.width > 0, clamped || rect.contains(point) else { return nil }
            return CGPoint(
                x: max(0, min(pageSize.width - 1, (point.x - rect.minX) * pageSize.width / rect.width)),
                y: max(0, min(pageSize.height - 1, (point.y - rect.minY) * pageSize.height / rect.height))
            )
        }
    }

    #if os(macOS)
        import AppKit

        struct RemoteBrowserCanvas: NSViewRepresentable {
            let image: CGImage?
            let frame: RemoteBrowserFrame?
            let acceptsInput: Bool
            let keyboardRequested: Bool
            var allowsLocalZoom = false
            var zoomIdentity = ""
            var focusRequest: UUID? = nil
            var isSimulator = false
            var onCopy: (() -> Void)?
            var onPaste: (() -> Void)?
            let send: (RemoteBrowserOperation) -> Void
            func makeNSView(context: Context) -> BrowserCanvasNSView {
                BrowserCanvasNSView()
            }

            func updateNSView(_ view: BrowserCanvasNSView, context: Context) {
                view.image = image
                view.pageSize = frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
                view.acceptsInput = acceptsInput
                view.focusRequest = focusRequest
                view.send = send
                view.onCopy = onCopy
                view.onPaste = onPaste
                view.needsDisplay = true
            }
        }

        final class BrowserCanvasNSView: NSView, @preconcurrency NSTextInputClient {
            @Dependency(ClipboardClient.self) private var clipboard
            var image: CGImage?
            var pageSize = CGSize.zero
            var acceptsInput = false
            var focusRequest: UUID? {
                didSet {
                    guard
                        focusRequest != oldValue, focusRequest != nil, acceptsInput,
                        let window, window.firstResponder !== self else { return }
                    window.makeFirstResponder(self)
                }
            }

            var send: (RemoteBrowserOperation) -> Void = { _ in }
            var onCopy: (() -> Void)?
            var onPaste: (() -> Void)?
            private var marked = NSAttributedString(string: "")
            private var pointerTrackingArea: NSTrackingArea?
            override var isFlipped: Bool {
                true
            }

            override var acceptsFirstResponder: Bool {
                acceptsInput
            }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                if let pointerTrackingArea {
                    removeTrackingArea(pointerTrackingArea)
                }
                let area = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                addTrackingArea(area)
                pointerTrackingArea = area
            }

            override func draw(_ dirtyRect: NSRect) {
                NSColor.black.setFill()
                bounds.fill()
                guard let image else { return }
                let target = RemoteBrowserGeometry.imageRect(viewSize: bounds.size, pageSize: pageSize)
                NSImage(cgImage: image, size: target.size).draw(
                    in: target,
                    from: .zero,
                    operation: .copy,
                    fraction: 1,
                    respectFlipped: true,
                    hints: nil
                )
            }

            private func modifiers(_ event: NSEvent) -> Int {
                (event.modifierFlags.contains(.option) ? 1 : 0) | (event.modifierFlags.contains(.control) ? 2 : 0)
                    | (event.modifierFlags.contains(.command) ? 4 : 0) | (event.modifierFlags.contains(.shift) ? 8 : 0)
            }

            private func pointer(_ event: NSEvent, kind: RemoteBrowserPointer.Kind, button: RemoteBrowserPointer.Button = .none, buttons: Int = 0) {
                guard
                    acceptsInput, let point = RemoteBrowserGeometry.pagePoint(
                        convert(event.locationInWindow, from: nil),
                        viewSize: bounds.size,
                        pageSize: pageSize,
                        clamped: kind == .up || (kind == .move && buttons != 0)
                    ) else { return }
                let clickCount = kind == .down || kind == .up ? min(3, event.clickCount) : 0
                send(.pointer(.init(
                    kind,
                    x: point.x,
                    y: point.y,
                    button: button,
                    buttons: buttons,
                    modifiers: modifiers(event),
                    clickCount: clickCount,
                    deltaX: kind == .scroll ? max(-4_096, min(4_096, -event.scrollingDeltaX)) : 0,
                    deltaY: kind == .scroll ? max(-4_096, min(4_096, -event.scrollingDeltaY)) : 0
                )))
            }

            override func mouseDown(with event: NSEvent) {
                window?.makeFirstResponder(self)
                pointer(event, kind: .down, button: .left, buttons: 1)
            }

            override func mouseUp(with event: NSEvent) {
                pointer(event, kind: .up, button: .left)
            }

            override func mouseMoved(with event: NSEvent) {
                pointer(event, kind: .move)
            }

            override func mouseDragged(with event: NSEvent) {
                pointer(event, kind: .move, button: .left, buttons: 1)
            }

            override func rightMouseDown(with event: NSEvent) {
                pointer(event, kind: .down, button: .right, buttons: 2)
            }

            override func rightMouseUp(with event: NSEvent) {
                pointer(event, kind: .up, button: .right)
            }

            override func scrollWheel(with event: NSEvent) {
                pointer(event, kind: .scroll)
            }

            override func keyDown(with event: NSEvent) {
                guard acceptsInput else { return }
                let keys: [UInt16: (String, Int)] = [
                    123: ("ArrowLeft", 37), 124: ("ArrowRight", 39), 125: ("ArrowDown", 40), 126: ("ArrowUp", 38),
                    115: ("Home", 36), 119: ("End", 35), 116: ("PageUp", 33), 121: ("PageDown", 34),
                    48: ("Tab", 9), 53: ("Escape", 27), 117: ("Delete", 46),
                ]
                if marked.length == 0, let key = keys[event.keyCode] {
                    send(.key(.init(key.0, keyCode: key.1, modifiers: modifiers(event))))
                    return
                }
                if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c", let onCopy {
                    onCopy()
                } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
                    paste(nil)
                } else if event.modifierFlags.intersection([.command, .control]).isEmpty {
                    interpretKeyEvents([event])
                } else if let value = event.charactersIgnoringModifiers, let code = value.uppercased().utf16.first {
                    send(.key(.init(value, keyCode: Int(code), modifiers: modifiers(event))))
                }
            }

            @objc
            func copy(_ sender: Any?) {
                if acceptsInput {
                    onCopy?()
                }
            }

            @objc
            func paste(_ sender: Any?) {
                guard acceptsInput else { return }
                if let onPaste {
                    onPaste()
                } else if let value = clipboard.getString() {
                    send(.text(value))
                }
            }

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                guard
                    acceptsInput, window?.firstResponder === self,
                    event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c" where onCopy != nil: copy(nil)
                    return true
                case "v": paste(nil)
                    return true
                default: return false
                }
            }

            func insertText(_ string: Any, replacementRange: NSRange) {
                guard acceptsInput else { return }
                let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
                marked = NSAttributedString(string: "")
                if !value.isEmpty {
                    send(.text(value))
                }
            }

            override func doCommand(by selector: Selector) {
                let keys: [String: (String, Int)] = [
                    "insertNewline:": ("Enter", 13),
                    "deleteBackward:": ("Backspace", 8),
                    "deleteForward:": ("Delete", 46),
                    "insertTab:": ("Tab", 9),
                    "cancelOperation:": ("Escape", 27),
                    "moveLeft:": ("ArrowLeft", 37),
                    "moveRight:": ("ArrowRight", 39),
                    "moveUp:": ("ArrowUp", 38),
                    "moveDown:": ("ArrowDown", 40),
                    "moveToBeginningOfLine:": ("Home", 36),
                    "moveToEndOfLine:": ("End", 35),
                ]
                if acceptsInput, let key = keys[NSStringFromSelector(selector)] {
                    send(.key(.init(key.0, keyCode: key.1)))
                }
            }

            func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
                marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
            }

            func unmarkText() {
                marked = NSAttributedString(string: "")
            }

            func selectedRange() -> NSRange {
                NSRange(location: marked.length, length: 0)
            }

            func markedRange() -> NSRange {
                NSRange(location: marked.length == 0 ? NSNotFound : 0, length: marked.length)
            }

            func hasMarkedText() -> Bool {
                marked.length != 0
            }

            func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
                nil
            }

            func validAttributesForMarkedText() -> [NSAttributedString.Key] {
                []
            }

            func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
                window?.convertToScreen(convert(NSRect(x: 0, y: bounds.height - 24, width: 1, height: 24), to: nil)) ?? .zero
            }

            func characterIndex(for point: NSPoint) -> Int {
                0
            }
        }
    #elseif os(iOS)
        import UIKit

        struct RemoteBrowserCanvas: UIViewRepresentable {
            let image: CGImage?
            let frame: RemoteBrowserFrame?
            let acceptsInput: Bool
            let keyboardRequested: Bool
            var allowsLocalZoom = false
            var zoomIdentity = ""
            var focusRequest: UUID? = nil
            var isSimulator = false
            var onCopy: (() -> Void)?
            var onPaste: (() -> Void)?
            let send: (RemoteBrowserOperation) -> Void
            func makeUIView(context: Context) -> BrowserCanvasUIView {
                BrowserCanvasUIView()
            }

            func updateUIView(_ view: BrowserCanvasUIView, context: Context) {
                view.preview.update(image: image, identity: zoomIdentity)
                view.allowsLocalZoom = allowsLocalZoom
                view.pageSize = frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
                view.acceptsInput = acceptsInput
                view.send = send
                view.isSimulator = isSimulator
                view.keyboard.send = send
                view.keyboard.onCopy = onCopy
                view.keyboard.onPaste = onPaste
                if keyboardRequested && acceptsInput {
                    if !view.keyboard.isFirstResponder {
                        view.keyboard.becomeFirstResponder()
                    }
                } else if view.keyboard.isFirstResponder {
                    view.keyboard.resignFirstResponder()
                }
            }

            static func dismantleUIView(_ view: BrowserCanvasUIView, coordinator: ()) {
                view.keyboard.resignFirstResponder()
            }
        }

        final class BrowserCanvasUIView: UIView {
            var isSimulator = false
            let preview = LocalImageScrollView()
            fileprivate let keyboard = BrowserKeyboardInput()
            var pageSize = CGSize.zero
            var allowsLocalZoom = false {
                didSet {
                    if allowsLocalZoom != oldValue {
                        updateGestures()
                    }
                }
            }

            var acceptsInput = false {
                didSet {
                    if acceptsInput != oldValue {
                        updateGestures()
                    }
                }
            }

            private var inputGestures: [UIGestureRecognizer] = []
            var send: (RemoteBrowserOperation) -> Void = { _ in }
            private var previous = CGPoint.zero
            override init(frame: CGRect) {
                super.init(frame: frame)
                backgroundColor = .black
                preview.zoomEnabled = false
                addSubview(preview)
                keyboard.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                keyboard.alpha = 0.01
                addSubview(keyboard)
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
                let pan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
                // One finger scrolls; two fingers drag a page element/selection.
                let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
                drag.minimumNumberOfTouches = 2
                pan.maximumNumberOfTouches = 1
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
                hold.minimumPressDuration = 0.3
                tap.require(toFail: hold)
                self.inputGestures = [tap, pan, drag, hold]
                for gesture in inputGestures {
                    addGestureRecognizer(gesture)
                }
                updateGestures()
            }

            required init?(coder: NSCoder) {
                nil
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                preview.frame = bounds
            }

            private func updateGestures() {
                preview.zoomEnabled = allowsLocalZoom && !acceptsInput
                for gesture in inputGestures {
                    gesture.isEnabled = acceptsInput
                }
            }

            private func point(_ gesture: UIGestureRecognizer, clamped: Bool = false) -> CGPoint? {
                guard acceptsInput else { return nil }
                return RemoteBrowserGeometry.pagePoint(gesture.location(in: self), viewSize: bounds.size, pageSize: pageSize, clamped: clamped)
            }

            @objc
            private func tapped(_ gesture: UITapGestureRecognizer) {
                guard let point = point(gesture) else { return }
                send(.pointer(.init(.down, x: point.x, y: point.y, button: .left, buttons: 1)))
                send(.pointer(.init(.up, x: point.x, y: point.y, button: .left)))
            }

            @objc
            private func scrolled(_ gesture: UIPanGestureRecognizer) {
                if isSimulator {
                    dragged(gesture)
                    return
                }
                let translation = gesture.translation(in: self)
                defer { previous = translation }
                guard gesture.state == .changed, let point = point(gesture) else { return }
                let rect = RemoteBrowserGeometry.imageRect(viewSize: bounds.size, pageSize: pageSize)
                let scale = pageSize.width / max(1, rect.width)
                send(.pointer(.init(
                    .scroll,
                    x: point.x,
                    y: point.y,
                    deltaX: max(-4_096, min(4_096, (previous.x - translation.x) * scale)),
                    deltaY: max(-4_096, min(4_096, (previous.y - translation.y) * scale))
                )))
            }

            @objc
            private func held(_ gesture: UILongPressGestureRecognizer) {
                guard let point = point(gesture, clamped: gesture.state != .began) else { return }
                let kind: RemoteBrowserPointer.Kind = gesture.state == .began ? .down : gesture.state == .changed ? .move : .up
                send(.pointer(.init(kind, x: point.x, y: point.y, button: .left, buttons: kind == .up ? 0 : 1)))
            }

            @objc
            private func dragged(_ gesture: UIPanGestureRecognizer) {
                guard let point = point(gesture, clamped: gesture.state != .began) else { return }
                let kind: RemoteBrowserPointer.Kind = gesture.state == .began ? .down : gesture.state == .changed ? .move : .up
                send(.pointer(.init(kind, x: point.x, y: point.y, button: .left, buttons: kind == .up ? 0 : 1)))
            }
        }

        /// UIKit owns composition/candidate UI. Only committed text crosses the wire.
        final private class BrowserKeyboardInput: UITextView, UITextViewDelegate {
            var send: (RemoteBrowserOperation) -> Void = { _ in }
            var onCopy: (() -> Void)?
            var onPaste: (() -> Void)?
            private let sentinel = "\u{200B}"
            init() {
                super.init(frame: .zero, textContainer: nil)
                delegate = self
                autocorrectionType = .no
                autocapitalizationType = .none
                smartQuotesType = .no
                smartDashesType = .no
                reset()
            }

            required init?(coder: NSCoder) {
                nil
            }

            override func copy(_ sender: Any?) {
                if let onCopy {
                    onCopy()
                } else {
                    super.copy(sender)
                }
            }

            override func paste(_ sender: Any?) {
                if let onPaste {
                    onPaste()
                } else {
                    super.paste(sender)
                }
            }

            private func reset() {
                text = sentinel
                selectedRange = NSRange(location: 1, length: 0)
            }

            func textViewDidChange(_ textView: UITextView) {
                guard markedTextRange == nil else { return }
                let value = text.hasPrefix(sentinel) ? String(text.dropFirst()) : text ?? ""
                if !value.isEmpty {
                    send(.text(value))
                }
                reset()
            }

            override func deleteBackward() {
                if markedTextRange == nil, text == sentinel {
                    send(.key(.init("Backspace", keyCode: 8)))
                } else {
                    super.deleteBackward()
                }
            }

            override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
                guard markedTextRange == nil else { super.pressesBegan(presses, with: event)
                    return
                }
                let keys: [UIKeyboardHIDUsage: (String, Int)] = [
                    .keyboardLeftArrow: ("ArrowLeft", 37), .keyboardRightArrow: ("ArrowRight", 39),
                    .keyboardUpArrow: ("ArrowUp", 38), .keyboardDownArrow: ("ArrowDown", 40),
                    .keyboardHome: ("Home", 36), .keyboardEnd: ("End", 35),
                    .keyboardPageUp: ("PageUp", 33), .keyboardPageDown: ("PageDown", 34),
                    .keyboardTab: ("Tab", 9), .keyboardEscape: ("Escape", 27),
                ]
                var remaining = presses
                for press in presses {
                    guard let key = press.key else { continue }
                    let flags = key.modifierFlags
                    if flags.contains(.command) {
                        if key.charactersIgnoringModifiers.lowercased() == "c", onCopy != nil {
                            copy(nil)
                            remaining.remove(press)
                            continue
                        }
                        if key.charactersIgnoringModifiers.lowercased() == "v", onPaste != nil {
                            paste(nil)
                            remaining.remove(press)
                            continue
                        }
                    }
                    let modifiers = (flags.contains(.alternate) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
                        | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
                    var value = keys[key.keyCode]
                    if
                        value == nil, !flags.intersection([.command, .control]).isEmpty,
                        key.charactersIgnoringModifiers.lowercased() != "v",
                        let code = key.charactersIgnoringModifiers.uppercased().utf16.first, code < 128 {
                        value = (key.charactersIgnoringModifiers, Int(code))
                    }
                    guard let value else { continue }
                    send(.key(.init(value.0, keyCode: value.1, modifiers: modifiers)))
                    remaining.remove(press)
                }
                if !remaining.isEmpty {
                    super.pressesBegan(remaining, with: event)
                }
            }

            func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
                if text == "\n", markedTextRange == nil {
                    send(.key(.init("Enter", keyCode: 13)))
                    return false
                }
                return true
            }
        }
    #endif
#endif
