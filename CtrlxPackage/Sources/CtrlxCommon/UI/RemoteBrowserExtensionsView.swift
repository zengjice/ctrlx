#if os(macOS) || os(iOS)
    import CtrlxNetworking
    import Dependencies
    import SwiftUI
    import UniformTypeIdentifiers

    enum RemoteBrowserExtensionInitialView {
        case manager
        case window
    }

    @MainActor
    struct RemoteBrowserExtensionsView: View {
        let client: ViewerRelayClient
        let initialStoreID: String?
        let initialView: RemoteBrowserExtensionInitialView
        let onOpenBrowser: (RemoteBrowserTab) -> Void
        @State private var canBrowseStore = false
        @State private var preparedInitialStore = false
        @State private var session: RemoteBrowserSession
        @State private var entries: [RemoteBrowserExtension] = []
        @State private var preview: RemoteBrowserExtensionPreview?
        @State private var storeLink = ""
        @State private var importing = false
        @State private var replacingID: String?
        @State private var showsWindow: Bool
        @State private var keyboard = false
        @State private var image: CGImage?
        @State private var displayedFrame: RemoteBrowserFrame?
        @State private var viewport = CGSize.zero
        @State private var status: String?
        @State private var failure: String?
        @State private var operation: Task<Void, Never>?
        @State private var operationID = UUID()
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.displayScale) private var displayScale
        @Dependency(ClipboardClient.self) private var clipboard

        init(
            tab: RemoteBrowserTab,
            client: ViewerRelayClient,
            initialStoreID: String? = nil,
            initialView: RemoteBrowserExtensionInitialView = .manager,
            onOpenBrowser: @escaping (RemoteBrowserTab) -> Void
        ) {
            self.client = client
            self.initialStoreID = initialStoreID
            self.initialView = initialView
            self.onOpenBrowser = onOpenBrowser
            _session = State(initialValue: RemoteBrowserSession(tab: tab, client: client, managesExtensions: true))
            _showsWindow = State(initialValue: initialView == .window)
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 12) {
                    Text("Extensions run on \(client.connectedHostName ?? "the Host Mac") and apply to its CtrlX browser across all sessions.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    if session.controlID == nil {
                        ContentUnavailableView(
                            initialView == .window ? "Open Extension Window" : "Manage Host Extensions",
                            symbol: initialView == .window ? .arrowUpRightSquare : .puzzlepiece,
                            description: initialView == .window
                                ? "Take control to open this page in a Chrome-style window with extension actions. Interaction on the Host takes control back."
                                : "Take control to install, update, enable, or remove extensions. Interaction on the Host takes control back."
                        )
                        Button {
                            Task { await session.takeControl(opensExtensionWindow: initialView == .window) }
                        } label: {
                            Label(initialView == .window ? "Open Page as Chrome Window" : "Take Extension Control", symbol: .eye)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.isTakingControl || !client.isHostConnected)
                        .accessibilityValue("Read Only")
                    } else {
                        Picker("View", selection: $showsWindow) {
                            Text("Extensions").tag(false)
                            Text("Window").tag(true)
                        }.pickerStyle(.segmented).padding(.horizontal)
                        if showsWindow {
                            nativeWindow
                        } else if let preview {
                            review(preview)
                        } else {
                            management
                        }
                    }
                    if let status {
                        HStack { ProgressView().controlSize(.small)
                            Text(status).font(.caption)
                        }.padding(.horizontal)
                    }
                    if let error = failure ?? session.error ?? session.frameError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal)
                    }
                }
                .padding(.bottom)
                .navigationTitle(initialView == .window ? "Extension Window" : "Browser Extensions")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .cancellationAction) {
                        if session.controlID != nil {
                            RemoteControlButton(title: "Release Control", isControlled: true) { cancelAndRelease() }
                        }
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, UTType(filenameExtension: "crx") ?? .data]) { result in
                    switch result {
                    case let .success(file):
                        run("Uploading extension package…") {
                            preview = try await session.prepareExtensionPackage(file: file, replacingID: replacingID) { fraction in
                                status = "Uploading \(Int(fraction * 100))%…"
                            }
                        }
                    case let .failure(error): failure = error.localizedDescription
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, idealWidth: 1_000, minHeight: 560, idealHeight: 750)
            #endif
            .task(id: scenePhase == .active && client.isHostConnected && client.hostSupportsBrowserExtensions) {
                guard scenePhase == .active, client.isHostConnected, client.hostSupportsBrowserExtensions else {
                    cancelAndRelease()
                    session.stop()
                    return
                }
                await session.watch()
            }
            .onChange(of: session.controlID) { _, value in
                if value == nil {
                    operationID = UUID()
                    operation?.cancel()
                    operation = nil
                    status = nil
                    preview = nil
                    entries = []
                    keyboard = false
                } else {
                    run("Loading extensions…") {
                        try await refresh()
                        if let initialStoreID, !preparedInitialStore {
                            preparedInitialStore = true
                            storeLink = initialStoreID
                            preview = try await session.performExtension(.prepareStore(input: initialStoreID, replacingID: entries.first { $0.id == initialStoreID }?.id)).extensions?.prepared
                        }
                    }
                }
            }
            .onChange(of: session.openedStoreTab) { _, tab in
                guard let tab else { return }
                client.rememberOpenedBrowser(tab)
                session.releaseControl()
                dismiss()
                onOpenBrowser(tab)
            }
            .onDisappear { operation?.cancel()
                session.stop()
            }
        }

        private var management: some View {
            VStack(spacing: 12) {
                HStack {
                    TextField("Chrome Web Store link or ID", text: $storeLink).textFieldStyle(.roundedBorder)
                    #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                    Button("Review") { prepareStore(storeLink) }.disabled(storeLink.isEmpty)
                }.padding(.horizontal)
                HStack {
                    if canBrowseStore {
                        Button("Browse Store") {
                            run("Opening Chrome Web Store…") { _ = try await session.performExtension(.openStore) }
                        }
                    }
                    Button("Import ZIP / CRX…") { replacingID = nil
                        importing = true
                    }
                    Spacer()
                    Button { run("Refreshing…") { try await refresh() } } label: {
                        Label("Refresh", symbol: .arrowClockwise).labelStyle(.iconOnly)
                    }
                }.padding(.horizontal)
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.name).font(.headline)
                        Text("\(entry.version) · \(entry.state.capitalized)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if entry.hasOptions == true {
                                Button("Settings") {
                                    run("Opening extension settings…") {
                                        _ = try await session.performExtension(.openOptions(entry.id))
                                        showsWindow = true
                                    }
                                }
                                .disabled(!entry.isEnabled)
                            }
                            Button(entry.isEnabled ? "Disable" : "Enable") {
                                run(entry.isEnabled ? "Disabling…" : "Confirm any permission request in the window…") {
                                    if !entry.isEnabled {
                                        showsWindow = true
                                    }
                                    _ = try await session.performExtension(.setEnabled(id: entry.id, enabled: !entry.isEnabled))
                                    try await refresh()
                                }
                            }
                            if entry.canUpdate {
                                Menu("Update") {
                                    Button("From ZIP / CRX…") { replacingID = entry.id
                                        importing = true
                                    }
                                    Button("From Chrome Web Store") { prepareStore(entry.id, replacing: entry.id) }
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                run("Confirm removal in the Chromium window…") {
                                    showsWindow = true
                                    _ = try await session.performExtension(.remove(entry.id))
                                    try await refresh()
                                }
                            } label: { Label("Remove", symbol: .trash).labelStyle(.iconOnly) }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
            }.disabled(status != nil)
        }

        private func review(_ package: RemoteBrowserExtensionPreview) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(package.name).font(.title2)
                        Text(package.previousVersion.map { "Update \($0) → \(package.version)" } ?? "Version \(package.version)")
                        Text(source(package.source)).font(.callout)
                        if let previous = package.previousSource, previous != package.source {
                            Text("Changes source from \(source(previous)).").font(.callout)
                        }
                        Text(package.extensionID).font(.caption.monospaced()).textSelection(.enabled)
                        permissionGroup("Permissions", package.permissions)
                        permissionGroup("Website access", package.hostPermissions)
                        permissionGroup("Content scripts", package.contentScriptMatches)
                        permissionGroup("Optional permissions", package.optionalPermissions + package.optionalHostPermissions)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Discard") { run("Discarding…") { _ = try await session.performExtension(.discard(package.id))
                        preview = nil
                    } }
                    Spacer()
                    Button(package.previousVersion == nil ? "Install on Host" : "Update on Host") {
                        run("Installing on Host…") {
                            // A failed submission may still finish on the Host.
                            // Return to the list so its runtime state can be refreshed.
                            preview = nil
                            _ = try await session.performExtension(.install(package.id))
                            try await refresh()
                        }
                    }.buttonStyle(.borderedProminent)
                }.disabled(status != nil)
            }.padding(.horizontal)
        }

        private func permissionGroup(_ title: String, _ values: [String]) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(values.isEmpty ? "None" : values.joined(separator: "\n")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }

        private func source(_ source: RemoteBrowserExtensionPreview.Source) -> String {
            switch source {
            case .zip: "ZIP · Unsigned package"
            case .crx: "CRX3 · Developer signature verified"
            case .webStore: "Chrome Web Store · Signed package"
            }
        }

        private var nativeWindow: some View {
            VStack(spacing: 8) {
                HStack {
                    Button { show(.page) } label: {
                        Label("Extension Window", symbol: .arrowUpRightSquare).labelStyle(.iconOnly)
                    }
                    .help("Show the Chrome-style extension window")
                    Button { show(.manager) } label: {
                        Label("Extension Advanced Management", symbol: .puzzlepiece).labelStyle(.iconOnly)
                    }
                    .help("Open Chromium's extension management page")
                    Spacer()
                    Button {
                        session.submit(.fit(width: Int(max(480, min(viewport.width, 2_560))), height: Int(max(360, min(viewport.height, 2_560)))))
                    } label: { Label("Fit Host Window", symbol: .arrowUpLeftAndArrowDownRight).labelStyle(.iconOnly) }
                        .disabled(displayedFrame == nil || status != nil)
                    Button {
                        if let text = clipboard.getString() {
                            session.submit(.text(text))
                        }
                    } label: { Label("Paste", symbol: .docOnClipboard).labelStyle(.iconOnly) }
                    #if os(iOS)
                        Button { keyboard.toggle() } label: { Label("Keyboard", symbol: .keyboard).labelStyle(.iconOnly) }
                    #endif
                }.disabled(status != nil).padding(.horizontal)
                RemoteBrowserCanvas(
                    image: image,
                    frame: displayedFrame,
                    acceptsInput: session.controlID != nil,
                    keyboardRequested: keyboard
                ) { input in
                    if let displayedFrame {
                        session.submit(input, generation: displayedFrame.generation)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    viewport = size
                    session.frameMaxDimension = RemoteBrowserGeometry.frameMaxDimension(
                        viewSize: size,
                        pageSize: session.frame.map { CGSize(width: $0.width, height: $0.height) } ?? size,
                        displayScale: displayScale
                    )
                }
                .overlay {
                    if image == nil {
                        ProgressView("Opening Host window…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(RemoteBrowserFrameDecoding(frame: session.frame, isAnnotating: false, image: $image, displayedFrame: $displayedFrame))
            }
        }

        private func prepareStore(_ input: String, replacing: String? = nil) {
            run("Downloading and checking permissions…") {
                preview = try await session.performExtension(.prepareStore(input: input, replacingID: replacing)).extensions?.prepared
            }
        }

        private func show(_ surface: RemoteBrowserExtensionSurface) {
            run("Opening Host window…") { _ = try await session.performExtension(.showSurface(surface)) }
        }

        private func refresh() async throws {
            let result = try await session.performExtension(.list).extensions
            entries = result?.entries ?? []
            canBrowseStore = result?.canBrowseStore == true
        }

        private func cancelAndRelease() {
            operationID = UUID()
            operation?.cancel()
            operation = nil
            status = nil
            session.releaseControl()
        }

        private func run(_ message: String, action: @escaping @MainActor () async throws -> Void) {
            guard operation == nil else { return }
            status = message
            failure = nil
            let current = UUID()
            operationID = current
            operation = Task {
                defer {
                    if operationID == current {
                        status = nil
                        operation = nil
                    }
                }
                do { try await action() }
                catch is CancellationError { return }
                catch {
                    if operationID == current {
                        failure = error.localizedDescription
                    }
                }
            }
        }
    }
#endif
