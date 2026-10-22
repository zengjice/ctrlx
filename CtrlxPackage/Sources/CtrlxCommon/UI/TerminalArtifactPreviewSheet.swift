#if os(macOS) || os(iOS)
    import CoreTransferable
    import Dependencies
    import SwiftUI
    import UniformTypeIdentifiers

    @MainActor
    public struct TerminalArtifactPreviewSheet: View {
        private let preview: TerminalArtifactPreview
        private let onOpenFiles: () -> Void
        private let isFullscreen: Bool
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @Dependency(ClipboardClient.self) private var clipboard
        @State private var data: Data?
        @State private var error: String?
        @State private var showsSource = false
        @State private var showsFullscreen = false
        @State private var renderer = ArtifactWebRenderer()

        public init(preview: TerminalArtifactPreview, onOpenFiles: @escaping () -> Void) {
            self.init(preview: preview, initialData: nil, isFullscreen: false, onOpenFiles: onOpenFiles)
        }

        private init(preview: TerminalArtifactPreview, initialData: Data?, isFullscreen: Bool, onOpenFiles: @escaping () -> Void) {
            self.preview = preview
            self.onOpenFiles = onOpenFiles
            self.isFullscreen = isFullscreen
            _data = State(initialValue: initialData)
        }

        private var isMermaid: Bool {
            TerminalArtifactPreview.isMermaid(path: preview.path)
        }

        private var title: String {
            (preview.path as NSString).lastPathComponent
        }

        public var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    if isMermaid {
                        Picker("Display", selection: $showsSource) {
                            Text("Diagram").tag(false)
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
                                if isMermaid, data != nil {
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
                            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
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
                                Button {
                                    if let png = renderer.png {
                                        clipboard.setImage(.init(data: png, format: .png))
                                    }
                                } label: { Label("Copy Image", symbol: .docOnDoc) }
                                    .disabled(renderer.png == nil)
                                if isMermaid {
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
                                Divider()
                                Button(action: onOpenFiles) { Label("Open in Files", symbol: .folder) }
                            } label: { Label("More", symbol: .ellipsisCircle) }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, idealWidth: 800, maxWidth: .infinity, minHeight: 360, idealHeight: 600, maxHeight: .infinity)
            #else
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .fullScreenCover(isPresented: $showsFullscreen) {
                TerminalArtifactPreviewSheet(preview: preview, initialData: data, isFullscreen: true, onOpenFiles: onOpenFiles)
            }
            #endif
            .task(id: colorScheme) { await load() }
            .onDisappear { renderer.stop() }
        }

        private func load() async {
            error = nil
            do {
                if data == nil {
                    data = try await preview.load()
                }
                guard let data else { return }
                let content: String
                if isMermaid {
                    content = String(decoding: data, as: UTF8.self)
                } else {
                    content = try await Task.detached(priority: .userInitiated) {
                        try ArtifactPreviewImage.png(from: data).base64EncodedString()
                    }.value
                }
                try Task.checkCancellation()
                renderer.load(content: content, mermaid: isMermaid, dark: colorScheme == .dark)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
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
#endif
