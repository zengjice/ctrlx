#if os(macOS) || os(iOS)
    import CtrlxNetworking
    import Dependencies
    import ImageIO
    import PDFKit
    import SwiftUI
    import Textual
    import UniformTypeIdentifiers

    /// Host files on all three surfaces. Only a local source can supply a native URL.
    @MainActor
    public struct WorkspaceFileBrowserView: View {
        @Environment(\.resourceTabActions) private var resourceActions
        @Bindable private var tab: FileBrowserTab
        private let source: FileBrowserSource
        @FocusState private var searchFocused: Bool
        @Dependency(ClipboardClient.self) private var clipboard
        @Environment(\.scenePhase) private var scenePhase
        @State private var upload = FileBrowserUpload()
        @State private var uploadRequest: UploadRequest?
        @State private var imageUploadRequest: ImageUploadRequest?
        @State private var destination: Destination?
        @State private var showsImporter = false
        @State private var showsFolderPrompt = false
        @State private var folderName = ""
        @State private var folderRequest: FolderRequest?
        @State private var actionMessage: String?
        @State private var isAnnotating = false

        private struct Destination {
            let path: String
            let source: FileBrowserSource
        }

        private struct UploadRequest: Identifiable {
            let id = UUID()
            let destination: Destination
            let urls: [URL]
        }

        private struct ImageUploadRequest {
            let id = UUID()
            let destination: Destination
            let content: WorkspaceClipboardContent
        }

        private struct FolderRequest: Identifiable {
            let id = UUID()
            let destination: Destination
            let name: String
        }

        public init(tab: FileBrowserTab, source: FileBrowserSource) {
            self.tab = tab
            self.source = source
        }

        public var body: some View {
            VStack(spacing: 0) {
                navigation.disabled(isAnnotating)
                if upload.isRunning {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(upload.filename).lineLimit(1)
                            if let path = uploadRequest?.destination.path {
                                Text("To: \(path)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            ProgressView(value: Double(upload.sentBytes), total: Double(max(1, upload.totalBytes)))
                            Text("\(upload.sentBytes.formatted(.byteCount(style: .file))) / \(upload.totalBytes.formatted(.byteCount(style: .file)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Cancel") {
                            uploadRequest = nil
                            imageUploadRequest = nil
                        }
                    }.padding(10)
                } else if let summary = upload.summary {
                    ScrollView {
                        Text(summary).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }.frame(maxHeight: 90)
                }
                if folderRequest != nil {
                    ProgressView("Creating folder…").padding(10)
                }
                if let actionMessage {
                    Text(actionMessage).font(.caption).textSelection(.enabled).padding(10)
                }
                Divider()
                #if os(macOS)
                    FileBrowserSplitView {
                        directory.disabled(isAnnotating)
                    } preview: {
                        preview
                    }
                #else
                    if tab.selectedFile == nil {
                        directory
                    } else {
                        preview
                    }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: tab.loadKey(source: source)) { await tab.load(source: source) }
            .task(id: previewKey) {
                await tab.loadPreview(source: source)
            }
            .task(id: uploadRequest?.id) {
                guard let request = uploadRequest else { return }
                await upload.run(urls: request.urls, directory: request.destination.path, source: request.destination.source) {
                    tab.refresh += 1
                }
                if uploadRequest?.id == request.id {
                    uploadRequest = nil
                }
            }
            .task(id: folderRequest?.id) { await createFolder() }
            .task(id: imageUploadRequest?.id) {
                guard let request = imageUploadRequest else { return }
                await upload.run(image: request.content, directory: request.destination.path, source: request.destination.source) {
                    tab.refresh += 1
                }
                if imageUploadRequest?.id == request.id {
                    imageUploadRequest = nil
                }
            }
            #if os(macOS)
            .onPasteCommand(of: [.png, .jpeg, .tiff]) { _ in pasteImage() }
            #endif
            .onDisappear {
                tab.releasePreview()
                // The iOS document picker can cover this view without closing its tab.
                if !showsImporter {
                    cancelWrites()
                }
            }
            .onChange(of: source.unavailableReason) { _, reason in
                if reason != nil {
                    cancelWrites()
                }
            }
            .onChange(of: source.id) { _, _ in cancelWrites() }
            .onChange(of: scenePhase) { _, phase in
                #if os(iOS)
                    if phase == .background {
                        cancelWrites()
                    }
                #endif
            }
            .alert("New Folder", isPresented: $showsFolderPrompt) {
                TextField("Folder name", text: $folderName)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Button("Cancel", role: .cancel) { destination = nil }
                Button("Create") {
                    if let destination {
                        folderRequest = .init(destination: destination, name: folderName)
                    }
                }.disabled(!SessionDirectoryName.isValid(folderName))
            } message: {
                Text("Create in \(destination?.path ?? ""). Enter one folder name, without /.")
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                guard let target = destination, target.source.id == source.id, source.unavailableReason == nil else { return }
                destination = nil
                switch result {
                case let .success(urls):
                    if !urls.isEmpty {
                        uploadRequest = .init(destination: target, urls: urls)
                    }
                case let .failure(error): actionMessage = error.localizedDescription
                }
            }
            .onChange(of: tab.searchFocusRequest, initial: true) { _, value in
                if value > 0 {
                    searchFocused = true
                }
            }
        }

        private struct PreviewKey: Hashable {
            let path: String?
            let refresh: Int
            let sourceID: String
            let unavailable: String?
            let downloadUnavailable: String?
        }

        private var previewKey: PreviewKey {
            .init(
                path: tab.selectedFile,
                refresh: tab.refresh,
                sourceID: source.id,
                unavailable: source.unavailableReason,
                downloadUnavailable: source.downloadUnavailableReason
            )
        }

        private func updateSearch(query: String, mode: FileBrowserSearchMode) {
            #if os(iOS)
                tab.updateSearch(query: query, mode: mode, dismissPreview: true)
            #else
                tab.updateSearch(query: query, mode: mode, dismissPreview: false)
            #endif
        }

        private var navigation: some View {
            VStack(spacing: 8) {
                HStack {
                    Button { tab.navigate(tab.path.map { ($0 as NSString).deletingLastPathComponent }) } label: {
                        Label("Up", symbol: .arrowUpCircleFill).labelStyle(.iconOnly)
                    }
                    .disabled(tab.path == nil || tab.path == "/")
                    Button { tab.navigate(tab.homeDirectory) } label: { Label("Home", symbol: .house).labelStyle(.iconOnly) }
                    TextField("Host directory", text: $tab.pathInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { tab.navigate(tab.pathInput) }
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                    if
                        let descriptor = tab.hostTab, let sessionID = descriptor.resourceSessionID,
                        let path = tab.selectedFile ?? tab.path, let actions = resourceActions {
                        ResourceAgentMenu(kind: .files, tabID: descriptor.id, sessionID: sessionID, grant: nil, path: path, request: actions.request)
                    }
                    Button { tab.refresh += 1 } label: { Label("Refresh", symbol: .arrowClockwise).labelStyle(.iconOnly) }
                    Menu {
                        Button {
                            guard captureDestination() else { return }
                            folderName = ""
                            showsFolderPrompt = true
                        } label: { Label("New Folder…", symbol: .folderBadgePlus) }
                            .accessibilityIdentifier("file-browser-new-folder")
                            .disabled(writesBusy || tab.path == nil || tab.isLoading || source.creationUnavailableReason != nil)
                        Button {
                            guard captureDestination() else { return }
                            showsImporter = true
                        } label: {
                            Label(source.localFileURL == nil ? "Upload Files…" : "Import Files…", symbol: .squareAndArrowUp)
                        }
                        .accessibilityIdentifier("file-browser-upload")
                        .disabled(writesBusy || tab.path == nil || tab.isLoading || source.uploadUnavailableReason != nil)
                        Button("Paste Image", action: pasteImage)
                            .disabled(writesBusy || tab.path == nil || source.uploadUnavailableReason != nil)
                            .accessibilityIdentifier("file-browser-paste-image")
                        if let reason = source.creationUnavailableReason ?? source.uploadUnavailableReason {
                            Text(reason)
                        }
                        Divider()
                        if tab.sourcePaneID != nil {
                            Button { tab.navigate(nil) } label: { Label("Source Pane Directory", symbol: .terminal) }
                        }
                        Toggle("Show Hidden Files", isOn: $tab.includeHidden)
                        Button("Copy Directory Path") {
                            if let path = tab.path {
                                clipboard.setString(path)
                            }
                        }
                    } label: { Label("File Browser Options", symbol: .ellipsisCircle).labelStyle(.iconOnly) }
                }
                HStack {
                    TextField("Search files", text: Binding(
                        get: { tab.query },
                        set: { updateSearch(query: $0, mode: tab.searchMode) }
                    )).textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                    Picker("Search", selection: Binding(
                        get: { tab.searchMode },
                        set: { updateSearch(query: tab.query, mode: $0) }
                    )) {
                        Text("Name").tag(FileBrowserSearchMode.name)
                        Text("Text").tag(FileBrowserSearchMode.content)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(10)
            .disabled(source.unavailableReason != nil)
        }

        private var writesBusy: Bool {
            uploadRequest != nil || imageUploadRequest != nil || upload.isRunning || folderRequest != nil
        }

        private func pasteImage() {
            guard captureDestination(), let destination else { return }
            do {
                let content = try clipboard.workspaceContent()
                guard content.kind != .text else { throw FileBrowserError.message("Copy an image to save it in this directory.") }
                imageUploadRequest = ImageUploadRequest(destination: destination, content: content)
            } catch { actionMessage = error.localizedDescription }
            self.destination = nil
        }

        private func captureDestination() -> Bool {
            guard let path = tab.path, !writesBusy, source.unavailableReason == nil else { return false }
            destination = Destination(path: path, source: source)
            actionMessage = nil
            return true
        }

        private func cancelWrites() {
            uploadRequest = nil
            imageUploadRequest = nil
            folderRequest = nil
            destination = nil
            showsImporter = false
            showsFolderPrompt = false
        }

        private func createFolder() async {
            guard let request = folderRequest else { return }
            defer {
                if folderRequest?.id == request.id {
                    folderRequest = nil
                    destination = nil
                }
            }
            do {
                guard let create = request.destination.source.createDirectory else {
                    throw FileBrowserError.message("Update the Host Mac to create folders.")
                }
                try Task.checkCancellation()
                _ = try await create(.init(parentDirectory: request.destination.path, name: request.name))
                try Task.checkCancellation()
                guard folderRequest?.id == request.id else { return }
                actionMessage = "Created \(request.name) in \(request.destination.path)."
                if tab.path == request.destination.path {
                    tab.query = ""
                    tab.selectedFile = nil
                }
                tab.refresh += 1
            } catch {
                if !Task.isCancelled, folderRequest?.id == request.id {
                    actionMessage = error.localizedDescription
                }
            }
        }

        private var directory: some View {
            VStack(spacing: 0) {
                if let error = tab.error {
                    Text(error).foregroundStyle(.secondary).padding().textSelection(.enabled)
                }
                if tab.isLoading {
                    ProgressView().padding()
                }
                List {
                    if let result = tab.searchResults {
                        ForEach(result.matches) { match in
                            VStack(alignment: .leading) {
                                row(match.entry)
                                Text(match.entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if let line = match.lineText {
                                    Text("\(match.lineNumber ?? 0): \(line)").font(.caption.monospaced()).lineLimit(2)
                                }
                            }
                        }
                        if result.isTruncated {
                            Text("Search limit reached. Narrow the directory or query.").font(.caption).foregroundStyle(.secondary)
                        }
                        if result.matches.isEmpty {
                            Text("No matches")
                        }
                    } else if let listing = tab.listing {
                        ForEach(listing.entries) { item in
                            FileBrowserTreeRow(item: item, tab: tab, source: source, depth: 0)
                        }
                        if listing.entries.isEmpty {
                            Text("Empty folder").foregroundStyle(.secondary)
                        }
                        if listing.nextOffset != nil {
                            Button("Load More") { Task { await tab.loadDirectory(listing.directory, more: true, source: source) } }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }

        private func row(_ item: FileBrowserEntry) -> some View {
            Button {
                if item.kind == .directory {
                    tab.navigate(item.path)
                } else {
                    tab.selectedFile = item.path
                }
            } label: {
                Label(item.name, symbol: item.kind == .directory ? .folder : .docPlaintextFill)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { Button("Copy Path") { clipboard.setString(item.path) } }
        }

        private var preview: some View {
            FileBrowserFilePreview(tab: tab, source: source, onEditingChanged: { isAnnotating = $0 })
                .id(FilePreviewIdentity(path: tab.selectedFile, refresh: tab.refresh, sourceID: source.id))
        }

        private struct FilePreviewIdentity: Hashable {
            let path: String?
            let refresh: Int
            let sourceID: String
        }
    }

    @MainActor
    private struct FileBrowserFilePreview: View {
        let tab: FileBrowserTab
        let source: FileBrowserSource
        let onEditingChanged: (Bool) -> Void
        @Environment(\.browserAnnotationContext) private var annotationContext
        @Dependency(ClipboardClient.self) private var clipboard
        @State private var capture = FilePreviewCapture()
        @State private var captureRequest: UUID?
        @State private var isAnnotating = false
        @State private var clipboardMessage: String?

        private var preferredTarget: AgentImageTarget? {
            annotationContext?.targets.first { $0.paneID == tab.sourcePaneID }
        }

        var body: some View {
            VStack(spacing: 0) {
                if let path = tab.selectedFile {
                    let key = OpenKey(
                        path: path,
                        sourceID: source.id,
                        unavailable: source.unavailableReason,
                        downloadUnavailable: source.downloadUnavailableReason
                    )
                    HStack {
                        #if os(iOS)
                            Button { tab.selectedFile = nil } label: { Label("Files", symbol: .chevronLeft) }
                        #endif
                        Text((path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if annotationContext != nil {
                            Button { captureRequest = UUID() } label: {
                                Label("Annotate Screenshot", symbol: .pencilLine).labelStyle(.iconOnly)
                            }
                            .disabled(annotationContext?.isAvailable != true || tab.isPreviewLoading || !supportsAnnotation(path))
                            .help("Mark the visible file preview and add it to an Agent input")
                            .accessibilityIdentifier("file-annotate")
                        }
                        Menu {
                            Button("Copy Path") { clipboard.setString(path) }
                            if
                                let data = tab.previewData, tab.preview?.kind == .text || tab.preview?.kind == .markdown,
                                let text = String(data: data, encoding: .utf8) {
                                Button("Copy Text") { clipboard.setString(text) }
                            }
                            if let data = tab.previewData, tab.preview?.kind == .image {
                                Button("Copy Image") {
                                    do {
                                        try clipboard.setWorkspaceContent(WorkspaceClipboard.image(data))
                                        clipboardMessage = "Image copied."
                                    } catch { clipboardMessage = error.localizedDescription }
                                }
                            }
                            Button("Refresh Preview") { tab.refresh += 1 }
                        } label: { Label("File Actions", symbol: .ellipsisCircle).labelStyle(.iconOnly) }
                    }.disabled(isAnnotating).padding(10)
                    if let clipboardMessage {
                        Text(clipboardMessage).font(.caption).padding(.horizontal, 10)
                    }
                    Divider()
                    FileBrowserOpenActions(path: path, source: source)
                        .id(key)
                        .disabled(isAnnotating)
                    BrowserAnnotationSurface(
                        preferredTarget: preferredTarget,
                        requiresRecipientSelection: preferredTarget == nil,
                        capture: { try await capture.capture(filename: path) },
                        onEditingChanged: { editing in
                            isAnnotating = editing
                            onEditingChanged(editing)
                        },
                        captureRequest: captureRequest,
                        identifierPrefix: "file"
                    ) {
                        VStack(spacing: 0) { fileContent(path) }
                            // Reconnection resets downloads/players, not the frozen annotation.
                            .id(key)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView("Select a File", symbol: .docPlaintextFill, description: "Preview files from the Host without downloading a folder.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func supportsAnnotation(_ path: String) -> Bool {
            if FileBrowserOfficeDocument.supports(path: path) || FileBrowserVideo.supports(path: path) {
                return true
            }
            if let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .movie) {
                return true
            }
            guard tab.previewData != nil, let kind = tab.preview?.kind else { return false }
            return [.text, .markdown, .image, .pdf].contains(kind)
        }

        @ViewBuilder
        private func fileContent(_ path: String) -> some View {
            if tab.isPreviewLoading {
                ProgressView().padding()
            }
            if let error = tab.previewError {
                Text(error).padding().textSelection(.enabled)
            }
            if FileBrowserOfficeDocument.supports(path: path) {
                FileBrowserOfficePreview(path: path, source: source, capture: capture)
            } else if source.localFileURL == nil, FileBrowserVideo.supports(path: path) {
                FileBrowserVideoPreview(path: path, source: source, capture: capture)
            } else {
                #if os(macOS)
                    if let url = tab.previewURL {
                        FileBrowserMediaPreview(url: url, capture: capture).id(url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let data = tab.previewData, let info = tab.preview {
                        FileBrowserPreview(data: data, kind: info.kind, capture: capture).id(info.path)
                    } else {
                        Spacer()
                    }
                #else
                    if let data = tab.previewData, let info = tab.preview {
                        FileBrowserPreview(data: data, kind: info.kind, capture: capture).id(info.path)
                    } else {
                        Spacer()
                    }
                #endif
            }
        }

        private struct OpenKey: Hashable {
            let path: String
            let sourceID: String
            let unavailable: String?
            let downloadUnavailable: String?
        }
    }

    @MainActor
    private struct FileBrowserTreeRow: View {
        let item: FileBrowserEntry
        @Bindable var tab: FileBrowserTab
        let source: FileBrowserSource
        let depth: Int
        @Dependency(ClipboardClient.self) private var clipboard

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    #if os(macOS)
                        if item.kind == .directory, depth < 20 {
                            Button {
                                if tab.expanded.contains(item.path) {
                                    tab.expanded.remove(item.path)
                                } else {
                                    tab.expanded.insert(item.path)
                                }
                            } label: {
                                (tab.expanded.contains(item.path) ? Symbols.chevronDown : Symbols.chevronRight).image
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand \(item.name)")
                        }
                    #endif
                    Button {
                        if item.kind == .directory {
                            tab.navigate(item.path)
                        } else {
                            tab.selectedFile = item.path
                        }
                    } label: {
                        Label(item.name, symbol: item.kind == .directory ? .folder : .docPlaintextFill)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .contextMenu { Button("Copy Path") { clipboard.setString(item.path) } }
                #if os(macOS)
                    if tab.expanded.contains(item.path), depth < 20 {
                        Group {
                            if let listing = tab.listings[item.path] {
                                ForEach(listing.entries) { child in
                                    FileBrowserTreeRow(item: child, tab: tab, source: source, depth: depth + 1)
                                }
                                if listing.nextOffset != nil {
                                    Button("Load More") { Task { await tab.loadDirectory(item.path, more: true, source: source) } }
                                }
                            } else {
                                Button("Load Folder") { Task { await tab.loadDirectory(item.path, more: false, source: source) } }
                            }
                        }
                        .padding(.leading, 16)
                        .task(id: tab.listing?.revision) {
                            if tab.listings[item.path] == nil {
                                await tab.loadDirectory(item.path, more: false, source: source)
                            }
                        }
                    }
                #endif
            }
        }
    }

    struct FileBrowserPreview: View {
        let data: Data
        let kind: FileBrowserKind
        let capture: FilePreviewCapture
        @State private var image: CGImage?
        @State private var imageFailed = false
        @FocusState private var imageFocused: Bool
        #if os(iOS)
            @State private var readingScale: CGFloat = 1
            @GestureState private var magnification: CGFloat = 1
            @ScaledMetric(relativeTo: .body) private var bodySize = 17.0
            private var displayedReadingScale: CGFloat {
                min(3, max(1, readingScale * magnification))
            }
        #endif
        var body: some View {
            Group {
                switch kind {
                case .text,
                     .markdown:
                    FilePreviewSnapshotView(capture: capture) {
                        ScrollView([.vertical, .horizontal]) {
                            if kind == .markdown {
                                StructuredText(markdown: String(decoding: data, as: UTF8.self))
                                #if os(iOS)
                                    .textual.fontScale(displayedReadingScale)
                                #endif
                                    .textual.imageAttachmentLoader(FilePreviewAttachments())
                                    .textual.emojiAttachmentLoader(FilePreviewAttachments())
                                    .padding()
                                #if os(macOS)
                                    .background(MarkdownScrollSupport())
                                #endif
                            } else {
                                Text(String(decoding: data, as: UTF8.self))
                                #if os(iOS)
                                    .font(.system(size: bodySize * displayedReadingScale, design: .monospaced))
                                #else
                                    .font(.system(.body, design: .monospaced))
                                #endif
                                    .textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                        #if os(iOS)
                        .simultaneousGesture(MagnifyGesture()
                            .updating($magnification) { value, scale, _ in scale = value.magnification }
                            .onEnded { value in readingScale = min(3, max(1, readingScale * value.magnification)) })
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in readingScale = 1 }
                        .onDisappear { readingScale = 1 }
                        #endif
                    }
                case .image:
                    if let image {
                        FilePreviewSnapshotView(capture: capture) {
                            #if os(iOS)
                                LocalImagePreview(image: image).padding()
                            #else
                                Image(decorative: image, scale: 1).resizable().scaledToFit().padding()
                                    .focusable()
                                    .focused($imageFocused)
                                    .onTapGesture { imageFocused = true }
                                    .onCopyCommand {
                                        guard let content = try? WorkspaceClipboard.image(data) else { return [] }
                                        let provider = NSItemProvider()
                                        provider.registerDataRepresentation(
                                            forTypeIdentifier: content.kind == .png ? UTType.png.identifier : UTType.jpeg.identifier,
                                            visibility: .all
                                        ) { completion in
                                            completion(content.data, nil)
                                            return nil
                                        }
                                        return [provider]
                                    }
                            #endif
                        }
                    } else if imageFailed {
                        Text("This image cannot be decoded.")
                    } else {
                        ProgressView()
                    }
                case .pdf: FileBrowserPDF(data: data, capture: capture)
                default: Text("Preview unavailable")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: data) {
                guard kind == .image else { return }
                image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2_048,
                    ] as CFDictionary)
                }.value
                imageFailed = image == nil
            }
        }
    }

    /// A remote Markdown file must not silently fetch URLs or resolve file:// on the Viewer.
    private struct FilePreviewAttachments: AttachmentLoader {
        func attachment(for url: URL, text: String, environment: ColorEnvironmentValues) async throws -> AnyAttachment {
            throw FileBrowserError.message("Open image files directly to preview attachments.")
        }
    }

    #if os(macOS)
        private struct FileBrowserPDF: NSViewRepresentable {
            let data: Data
            let capture: FilePreviewCapture
            func makeNSView(context: Context) -> PDFView {
                let view = PDFView()
                view.autoScales = true
                registerPDFCapture(view, capture: capture, owner: context.coordinator.owner)
                return view
            }

            func updateNSView(_ view: PDFView, context: Context) {
                if context.coordinator.data != data {
                    view.document = PDFDocument(data: data)
                    context.coordinator.data = data
                }
            }

            func makeCoordinator() -> Coordinator {
                Coordinator()
            }

            final class Coordinator { var data: Data?
                let owner = UUID()
            }
        }
    #else
        private struct FileBrowserPDF: UIViewRepresentable {
            let data: Data
            let capture: FilePreviewCapture
            func makeUIView(context: Context) -> PDFView {
                let view = PDFView()
                view.autoScales = true
                registerPDFCapture(view, capture: capture, owner: context.coordinator.owner)
                return view
            }

            func updateUIView(_ view: PDFView, context: Context) {
                if context.coordinator.data != data {
                    view.document = PDFDocument(data: data)
                    context.coordinator.data = data
                }
            }

            func makeCoordinator() -> Coordinator {
                Coordinator()
            }

            final class Coordinator { var data: Data?
                let owner = UUID()
            }
        }
    #endif

    @MainActor
    private func registerPDFCapture(_ view: PDFView, capture: FilePreviewCapture, owner: UUID) {
        capture.bind(owner: owner) { [weak view] in
            guard let view, let document = view.document, let page = view.currentPage else {
                throw FileBrowserError.message("Wait for the PDF preview to load.")
            }
            return try .init(image: FilePreviewCapture.snapshot(view), detail: "Page \(document.index(for: page) + 1)")
        }
    }
#endif
