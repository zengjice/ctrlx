#if os(macOS) || os(iOS)
    #if os(macOS)
        import AppKit
    #endif
    import CoreTransferable
    import Dependencies
    import SwiftUI
    import UniformTypeIdentifiers

    @MainActor
    public struct TerminalArtifactPreviewSheet: View {
        private let preview: TerminalArtifactPreview
        private let onOpenFiles: (TerminalFileLinkRequest) -> Void
        private let onClose: (() -> Void)?
        private let configuresMacSheetWindow: Bool
        private let isFullscreen: Bool
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.openURL) private var openURL
        @Dependency(ClipboardClient.self) private var clipboard
        @State private var data: Data?
        @State private var error: String?
        @State private var showsSource = false
        @State private var showsFullscreen = false
        @State private var renderer = ArtifactWebRenderer()
        @State private var pendingDocumentLink: String?
        @State private var linkError: String?

        public init(preview: TerminalArtifactPreview, onOpenFiles: @escaping (TerminalFileLinkRequest) -> Void) {
            self.init(
                preview: preview,
                initialData: nil,
                isFullscreen: false,
                onOpenFiles: onOpenFiles,
                onClose: nil,
                configuresMacSheetWindow: true
            )
        }

        #if os(macOS)
            public init(
                preview: TerminalArtifactPreview,
                onOpenFiles: @escaping (TerminalFileLinkRequest) -> Void,
                onClose: @escaping () -> Void
            ) {
                self.init(
                    preview: preview,
                    initialData: nil,
                    isFullscreen: false,
                    onOpenFiles: onOpenFiles,
                    onClose: onClose,
                    configuresMacSheetWindow: false
                )
            }
        #endif

        private init(
            preview: TerminalArtifactPreview,
            initialData: Data?,
            isFullscreen: Bool,
            onOpenFiles: @escaping (TerminalFileLinkRequest) -> Void,
            onClose: (() -> Void)?,
            configuresMacSheetWindow: Bool
        ) {
            self.preview = preview
            self.onOpenFiles = onOpenFiles
            self.onClose = onClose
            self.configuresMacSheetWindow = configuresMacSheetWindow
            self.isFullscreen = isFullscreen
            _data = State(initialValue: initialData)
        }

        private var isMermaid: Bool {
            TerminalArtifactPreview.isMermaid(path: preview.path)
        }

        private var isMarkdown: Bool {
            TerminalArtifactPreview.isMarkdown(path: preview.path)
        }

        private var title: String {
            (preview.path as NSString).lastPathComponent
        }

        public var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    if isMermaid || isMarkdown {
                        Picker("Display", selection: $showsSource) {
                            Text(isMarkdown ? "Preview" : "Diagram").tag(false)
                            Text("Source").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                        .padding(12)
                    }
                    ZStack {
                        ArtifactWebPreview(renderer: renderer)
                            .opacity(showsSource || !renderer.isReady ? 0 : 1)
                            .allowsHitTesting(!showsSource && renderer.isReady)
                            .accessibilityHidden(showsSource || !renderer.isReady)
                        if showsSource, let data {
                            ScrollView([.horizontal, .vertical]) {
                                Text(String(decoding: data, as: UTF8.self))
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                        } else if let error = error ?? renderer.error {
                            VStack(spacing: 12) {
                                Label("Preview Unavailable", symbol: .exclamationmarkTriangle).font(.headline)
                                Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if isMermaid || isMarkdown, data != nil {
                                    Button("View Source") { showsSource = true }
                                }
                            }.padding(24)
                        } else if !renderer.isReady {
                            ProgressView(data == nil ? "Loading preview…" : "Rendering preview…")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(colorScheme == .dark ? Color(white: 0.118) : .white)
                .navigationTitle(title)
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { closePreview() }.keyboardShortcut(.cancelAction)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button { renderer.fit() } label: { Label("Fit to View", symbol: .arrowDownRightAndArrowUpLeft) }
                                    .disabled(!renderer.isReady || showsSource)
                                #if os(iOS)
                                    if !isFullscreen {
                                        Button { showsFullscreen = true } label: { Label("Full Screen", symbol: .arrowUpLeftAndArrowDownRight) }
                                            .disabled(data == nil)
                                    }
                                #endif
                                if !isMarkdown {
                                    Button {
                                        if let png = renderer.png {
                                            clipboard.setImage(.init(data: png, format: .png))
                                        }
                                    } label: { Label("Copy Image", symbol: .docOnDoc) }
                                        .disabled(renderer.png == nil)
                                }
                                if isMermaid || isMarkdown {
                                    Button("Copy Source") {
                                        if let data {
                                            clipboard.setString(String(decoding: data, as: UTF8.self))
                                        }
                                    }.disabled(data == nil)
                                }
                                if let png = renderer.png {
                                    ShareLink(
                                        item: PreviewExport(data: png, name: (title as NSString).deletingPathExtension + ".png"),
                                        preview: SharePreview(title, image: Symbols.docPlaintextFill.image)
                                    ) {
                                        Label("Share Image", symbol: .squareAndArrowUp)
                                    }
                                }
                                if isMarkdown, let data {
                                    ShareLink(item: MarkdownExport(data: data, name: title), preview: SharePreview(title)) {
                                        Label("Share Markdown", symbol: .squareAndArrowUp)
                                    }
                                }
                                Divider()
                                Button { onOpenFiles(preview.filesLink) } label: { Label("Open in Files", symbol: .folder) }
                                Button { onOpenFiles(preview.newFilesLink) } label: { Label("Open in New Files Tab", symbol: .folderBadgePlus) }
                            } label: { Label("More", symbol: .ellipsisCircle) }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 1_000, maxWidth: .infinity, minHeight: 420, idealHeight: 760, maxHeight: .infinity)
            .background {
                if configuresMacSheetWindow {
                    ArtifactPreviewSheetWindowConfigurator()
                }
            }
            #else
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .fullScreenCover(isPresented: $showsFullscreen) {
                TerminalArtifactPreviewSheet(
                    preview: preview,
                    initialData: data,
                    isFullscreen: true,
                    onOpenFiles: onOpenFiles,
                    onClose: nil,
                    configuresMacSheetWindow: false
                )
            }
            #endif
            .task(id: colorScheme) { await load() }
            .task(id: pendingDocumentLink) { await openDocumentLink() }
            .alert("Cannot Open Link", isPresented: Binding(get: { linkError != nil }, set: {
                if !$0 {
                    linkError = nil
                }
            })) {
                Button("OK", role: .cancel) { linkError = nil }
            } message: { Text(linkError ?? "") }
            .onDisappear { renderer.stop() }
        }

        private func closePreview() {
            if let onClose {
                onClose()
            } else {
                dismiss()
            }
        }

        private func load() async {
            error = nil
            do {
                if data == nil {
                    data = try await preview.load()
                }
                guard let data else { return }
                let content: String
                if isMermaid || isMarkdown {
                    content = String(decoding: data, as: UTF8.self)
                } else {
                    content = try await Task.detached(priority: .userInitiated) {
                        try ArtifactPreviewImage.png(from: data).base64EncodedString()
                    }.value
                }
                try Task.checkCancellation()
                renderer.load(
                    content: content,
                    kind: isMarkdown ? .markdown : isMermaid ? .mermaid : .image,
                    dark: colorScheme == .dark,
                    imageLoader: preview.loadDocumentImage,
                    openLink: { pendingDocumentLink = $0 }
                )
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }

        private func openDocumentLink() async {
            guard let reference = pendingDocumentLink else { return }
            defer {
                if pendingDocumentLink == reference {
                    pendingDocumentLink = nil
                }
            }
            if let url = URL(string: reference), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                openURL(url)
                return
            }
            do {
                let request = try preview.documentLink(reference)
                _ = try await TerminalFileDestination.resolve(path: request.path, context: preview.context, source: preview.source)
                try Task.checkCancellation()
                onOpenFiles(request)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    linkError = error.localizedDescription
                }
            }
        }
    }

    private struct PreviewExport: Transferable {
        let data: Data
        let name: String
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: .png) { $0.data }.suggestedFileName { $0.name }
        }
    }

    private struct MarkdownExport: Transferable {
        let data: Data
        let name: String
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(exportedContentType: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText) { $0.data }
                .suggestedFileName { $0.name }
        }
    }

    #if os(macOS)
        @MainActor
        enum ArtifactPreviewWindowSizing {
            static let minimumContentSize = NSSize(width: 600, height: 420)
            static let preferredContentSize = NSSize(width: 1_000, height: 760)

            static func initialContentSize(availableSize: NSSize) -> NSSize {
                NSSize(
                    width: min(preferredContentSize.width, max(minimumContentSize.width, availableSize.width * 0.8)),
                    height: min(preferredContentSize.height, max(minimumContentSize.height, availableSize.height * 0.8))
                )
            }

            static func configure(_ window: NSWindow, availableSize: NSSize) {
                window.styleMask.insert(.resizable)
                window.contentMinSize = minimumContentSize
                window.setContentSize(initialContentSize(availableSize: availableSize))
            }
        }

        /// SwiftUI sizes a macOS sheet from its minimum frame and does not make
        /// the sheet window resizable. Configure the AppKit window after it is
        /// attached so the preview opens at a useful size and can be resized.
        struct ArtifactPreviewSheetWindowConfigurator: NSViewRepresentable {
            func makeNSView(context: Context) -> SheetWindowView {
                SheetWindowView()
            }

            func updateNSView(_ view: SheetWindowView, context: Context) {
                view.configureIfNeeded()
            }

            final class SheetWindowView: NSView {
                private weak var configuredWindow: NSWindow?
                private var configurationTask: Task<Void, Never>?

                override func viewDidMoveToWindow() {
                    super.viewDidMoveToWindow()
                    configureIfNeeded()
                }

                func configureIfNeeded() {
                    guard configurationTask == nil, window !== configuredWindow else { return }
                    configurationTask = Task { @MainActor [weak self] in
                        for attempt in 0..<40 {
                            guard !Task.isCancelled, let self else { return }
                            if self.configureWindowIfReady() {
                                self.configurationTask = nil
                                return
                            }
                            if attempt < 39 {
                                try? await Task.sleep(for: .milliseconds(25))
                            }
                        }
                        self?.configurationTask = nil
                    }
                }

                private func configureWindowIfReady() -> Bool {
                    guard let window, window.isSheet, window !== configuredWindow else { return false }
                    configuredWindow = window
                    let availableSize = window.sheetParent?.contentLayoutRect.size
                        ?? window.screen?.visibleFrame.size
                        ?? ArtifactPreviewWindowSizing.preferredContentSize
                    ArtifactPreviewWindowSizing.configure(window, availableSize: availableSize)
                    return true
                }
            }
        }
    #endif
#endif
